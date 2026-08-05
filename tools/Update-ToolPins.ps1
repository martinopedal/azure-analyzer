#requires -Version 7.0
<#
.SYNOPSIS
    Weekly auto-update driver for wrapped tool pins.

.DESCRIPTION
    Reads tools/tool-manifest.json; for each tool with an `upstream` block,
    queries the releaseApi and compares against `currentPin`. ALL changed pins
    are collected first, then applied together in a single branch + commit + PR.
    One batched PR per run, not one PR per tool. Branch name is stable and
    predictable: chore/bump-tool-pins-<yyyyMMdd>. The chore/bump- prefix
    preserves the closes-link-required.yml exemption.

    Breaking-change heuristic (`$BreakingPatterns`) is applied across the batch;
    if ANY tool trips it, the single PR receives the `needs-copilot-iteration`
    label and an @copilot mention that lists every tripped tool.

    After all pin writes the script invokes Generate-ToolCatalog.ps1,
    Generate-PermissionsIndex.ps1 and Generate-ReadmeFacts.ps1 so the batched
    PR never fails the tool-catalog-fresh, permissions-pages-fresh or
    readme-facts-fresh CI jobs.

    Idempotent: a re-run with no upstream changes exits cleanly without touching
    git. Uses `gh` CLI -- expects GH_TOKEN in env.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'tools' 'tool-manifest.json'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'modules' 'shared' 'Retry.ps1')

$BreakingPatterns = @(
    'BREAKING',
    'CHANGED:',
    'removed flag',
    'renamed',
    'schema'
)

function Get-UpstreamVersion {
    param([Parameter(Mandatory)][hashtable]$Upstream)
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'azure-analyzer-auto-update' }
    if ($env:GH_TOKEN) { $headers['Authorization'] = "Bearer $env:GH_TOKEN" }

    $maxAttempts = 3
    for ($i = 1; $i -le $maxAttempts; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $Upstream.releaseApi -Headers $headers -TimeoutSec 30
            if ($Upstream.pinType -eq 'sha') {
                return [pscustomobject]@{
                    Version = $resp.sha.Substring(0, 12)
                    Notes   = $resp.commit.message
                    Url     = $resp.html_url
                }
            } else {
                return [pscustomobject]@{
                    Version = ($resp.tag_name -replace '^v', '')
                    Notes   = $resp.body
                    Url     = $resp.html_url
                }
            }
        } catch {
            if ($i -eq $maxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $i))
        }
    }
}

function Test-BreakingChange {
    param([string]$Notes)
    if (-not $Notes) { return $false }
    foreach ($p in $BreakingPatterns) {
        if ($Notes -match [regex]::Escape($p)) { return $true }
    }
    return $false
}

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$MaxAttempts = 3
    )

    return Invoke-WithRetry -MaxAttempts $MaxAttempts -InitialDelaySeconds 1 -MaxDelaySeconds 5 -ScriptBlock {
        $output = & git @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $joined = ($output -join [Environment]::NewLine).Trim()
            throw [System.Exception]::new("git $($Arguments -join ' ') failed: $joined")
        }
        return $output
    }
}

function Test-LocalBranchExists {
    param([Parameter(Mandatory)][string]$Branch)
    $null = & git show-ref --verify --quiet ("refs/heads/$Branch") 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Test-RemoteBranchExists {
    param([Parameter(Mandatory)][string]$Branch)
    $remoteHeads = Invoke-GitCommand -Arguments @('ls-remote', '--heads', 'origin', $Branch)
    return -not [string]::IsNullOrWhiteSpace(($remoteHeads -join '').Trim())
}

function Initialize-ToolUpdateBranch {
    param([Parameter(Mandatory)][string]$Branch)

    Invoke-GitCommand -Arguments @('fetch', 'origin', 'main') | Out-Null
    $remoteBranchExists = Test-RemoteBranchExists -Branch $Branch
    $localBranchExists = Test-LocalBranchExists -Branch $Branch

    if ($remoteBranchExists -or $localBranchExists) {
        if ($remoteBranchExists -and -not $localBranchExists) {
            Invoke-GitCommand -Arguments @('checkout', '-B', $Branch, "origin/$Branch") | Out-Null
        } else {
            Invoke-GitCommand -Arguments @('checkout', $Branch) | Out-Null
        }
        Invoke-GitCommand -Arguments @('reset', '--hard', 'origin/main') | Out-Null
    } else {
        Invoke-GitCommand -Arguments @('checkout', '-b', $Branch) | Out-Null
    }

    return [pscustomobject]@{
        RemoteBranchExists = $remoteBranchExists
    }
}

function Get-OpenPullRequestForBranch {
    param([Parameter(Mandatory)][string]$Branch)

    $prNumberRaw = & gh pr list --head $Branch --base main --state open --json number --jq '.[0].number' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$prNumberRaw)) {
        return $null
    }

    return "$prNumberRaw".Trim()
}

$manifestJson = Get-Content $ManifestPath -Raw
$manifest = $manifestJson | ConvertFrom-Json -AsHashtable

# --- Phase 1: collect all changes (no git ops yet) ---
$bumps = [System.Collections.Generic.List[hashtable]]::new()

foreach ($tool in $manifest.tools) {
    if (-not ($tool.ContainsKey('upstream')) -or -not $tool.upstream) { continue }
    $name = $tool.name
    Write-Host "==> Checking $name"

    try {
        $latest = Get-UpstreamVersion -Upstream $tool.upstream
    } catch {
        Write-Warning "${name}: upstream check failed -- $($_.Exception.Message)"
        continue
    }

    $current = $tool.upstream.currentPin
    if ($current -eq $latest.Version) {
        Write-Host "   $name : up to date ($current)"
        continue
    }
    if ($current -eq 'latest' -and $latest.Version -notmatch '^\d') {
        Write-Host "   $name : already at $current"
        continue
    }

    Write-Host "   $name : $current -> $($latest.Version)"
    $bumps.Add(@{
        Name       = $name
        OldPin     = $current
        NewPin     = $latest.Version
        Notes      = $latest.Notes
        Url        = $latest.Url
        Breaking   = (Test-BreakingChange -Notes $latest.Notes)
    })
}

if ($bumps.Count -eq 0) {
    Write-Host "No pin changes found. Nothing to do."
    exit 0
}

if ($DryRun) {
    Write-Host "[DryRun] Would bump $($bumps.Count) tool(s):"
    $bumps | ForEach-Object { Write-Host "  $($_.Name): $($_.OldPin) -> $($_.NewPin)" }
    exit 0
}

# --- Phase 2: single branch + commit + PR ---
$date   = (Get-Date -Format 'yyyyMMdd')
$branch = "chore/bump-tool-pins-$date"

$branchState = Initialize-ToolUpdateBranch -Branch $branch

# Apply all pin changes to the manifest on this branch
$manifestObj = (Get-Content $ManifestPath -Raw) | ConvertFrom-Json
foreach ($b in $bumps) {
    foreach ($t in $manifestObj.tools) {
        if ($t.name -eq $b.Name) { $t.upstream.currentPin = $b.NewPin }
    }
}
$newJson = $manifestObj | ConvertTo-Json -Depth 20
# Preserve original EOL (LF) and no trailing newline to match repo convention
$newJson = $newJson -replace "`r`n", "`n"
$origBytes = [IO.File]::ReadAllBytes($ManifestPath)
$origHasTrailingNewline = ($origBytes[-1] -eq 10)
if (-not $origHasTrailingNewline) { $newJson = $newJson.TrimEnd() }
[IO.File]::WriteAllText($ManifestPath, $newJson)

# Regenerate derived docs
$catalogScript    = Join-Path $RepoRoot 'scripts' 'Generate-ToolCatalog.ps1'
$permissionsScript = Join-Path $RepoRoot 'scripts' 'Generate-PermissionsIndex.ps1'
$readmeFactsScript = Join-Path $RepoRoot 'scripts' 'Generate-ReadmeFacts.ps1'

try {
    & pwsh -File $catalogScript -ErrorAction Stop | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Generate-ToolCatalog.ps1 exited $LASTEXITCODE" }
} catch {
    Write-Warning "Failed to regenerate tool catalogs: $($_.Exception.Message)"
    throw
}

try {
    & pwsh -File $permissionsScript -ErrorAction Stop | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Generate-PermissionsIndex.ps1 exited $LASTEXITCODE" }
} catch {
    Write-Warning "Failed to regenerate PERMISSIONS index: $($_.Exception.Message)"
    throw
}

try {
    & pwsh -File $readmeFactsScript -ErrorAction Stop | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Generate-ReadmeFacts.ps1 exited $LASTEXITCODE" }
} catch {
    Write-Warning "Failed to regenerate README facts: $($_.Exception.Message)"
    throw
}

# Stage everything
$catalogConsumer    = Join-Path $RepoRoot 'docs' 'reference' 'tool-catalog.md'
$catalogContributor = Join-Path $RepoRoot 'docs' 'reference' 'tool-catalog-contributor.md'
$permissionsRoot    = Join-Path $RepoRoot 'PERMISSIONS.md'
$permissionsRefDir  = Join-Path $RepoRoot 'docs' 'reference' 'permissions'
$permissionsConsDir = Join-Path $RepoRoot 'docs' 'consumer' 'permissions'
$readmeRoot         = Join-Path $RepoRoot 'README.md'

Invoke-GitCommand -Arguments @('add', $ManifestPath) | Out-Null
Invoke-GitCommand -Arguments @('add', $catalogConsumer, $catalogContributor) | Out-Null
Invoke-GitCommand -Arguments @('add', $permissionsRoot, $readmeRoot) | Out-Null
if (Test-Path -LiteralPath $permissionsRefDir) {
    Invoke-GitCommand -Arguments @('add', $permissionsRefDir) | Out-Null
}
if (Test-Path -LiteralPath $permissionsConsDir) {
    Invoke-GitCommand -Arguments @('add', $permissionsConsDir) | Out-Null
}

$pinLines = ($bumps | ForEach-Object { "$($_.Name): $($_.OldPin) -> $($_.NewPin)" }) -join "`n"
Invoke-GitCommand -Arguments @(
    'commit',
    '-m', "chore(deps): batch $($bumps.Count) wrapped-tool pin bumps ($date)",
    '-m', $pinLines,
    '-m', 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>'
) | Out-Null

if ($branchState.RemoteBranchExists) {
    Invoke-GitCommand -Arguments @('push', '--force-with-lease', '-u', 'origin', $branch) | Out-Null
} else {
    Invoke-GitCommand -Arguments @('push', '-u', 'origin', $branch) | Out-Null
}

# Build PR body
$tableRows = $bumps | ForEach-Object {
    "| $($_.Name) | ``$($_.OldPin)`` | ``$($_.NewPin)`` | $($_.Url) |"
}
$tableStr = @"
| Tool | Old pin | New pin | Upstream release |
|------|---------|---------|-----------------|
$($tableRows -join "`n")
"@

$anyBreaking = $bumps | Where-Object { $_.Breaking }
$breakingNote = ''
if ($anyBreaking) {
    $tripped = ($anyBreaking | ForEach-Object { "- **$($_.Name)**" }) -join "`n"
    $breakingNote = @"

---

> [!WARNING]
> Breaking-change heuristic matched for the following tools. @copilot please
> review their wrappers and normalizers and update flags or output parsing as
> needed.
>
$tripped
"@
}

$body = @"
Automated weekly pin bump -- $($bumps.Count) tool(s) updated.

N/A -- batched dependency maintenance; no single linked issue.

## Pin changes

$tableStr
$breakingNote

## Superseded PRs

These per-tool PRs are superseded by this batch and should be closed once CI
is green here (maintainer decides):

<!-- superseded list populated by automation; update as needed -->

---
*Generated by `tools/Update-ToolPins.ps1` on $date.*
"@

$labels = @('squad', 'enhancement', 'tool-auto-update')
if ($anyBreaking) { $labels += 'needs-copilot-iteration' }

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $body -Encoding utf8

$prTitle = "chore(deps): batch $($bumps.Count) wrapped-tool pin bumps ($date)"
$existingPr = Get-OpenPullRequestForBranch -Branch $branch
if ($existingPr) {
    & gh api -X PATCH "repos/martinopedal/azure-analyzer/pulls/$existingPr" `
        --field title=$prTitle `
        --field body="$(Get-Content $tmp -Raw)" | Out-Null
    foreach ($label in $labels) {
        gh pr edit $existingPr --add-label $label 2>$null | Out-Null
    }
    Write-Host "Updated PR #$existingPr"
} else {
    $prUrl = gh pr create `
        --title $prTitle `
        --body-file $tmp `
        --label ($labels -join ',') `
        --head $branch `
        --base main
    Write-Host "Created PR: $prUrl"
}
Remove-Item $tmp

Invoke-GitCommand -Arguments @('checkout', 'main') | Out-Null
Write-Host "Done. $($bumps.Count) tool(s) bumped on branch $branch."
