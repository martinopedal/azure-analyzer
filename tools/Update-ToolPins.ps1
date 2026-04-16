#requires -Version 7.0
<#
.SYNOPSIS
    Weekly auto-update driver for wrapped tool pins.

.DESCRIPTION
    Reads tools/tool-manifest.json; for each tool with an `upstream` block,
    queries the releaseApi, compares against `currentPin`, and (on change)
    creates a branch + commit + PR bumping the pin. Breaking-change heuristic
    in release notes triggers `needs-copilot-iteration` label + @copilot mention
    in the PR body.

    One PR per tool. Uses `gh` CLI — expects GH_TOKEN in env.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..' 'tools' 'tool-manifest.json'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

$manifestJson = Get-Content $ManifestPath -Raw
$manifest = $manifestJson | ConvertFrom-Json -AsHashtable

foreach ($tool in $manifest.tools) {
    if (-not $tool.upstream) { continue }
    $name = $tool.name
    Write-Host "==> Checking $name"

    try {
        $latest = Get-UpstreamVersion -Upstream $tool.upstream
    } catch {
        Write-Warning "${name}: upstream check failed — $($_.Exception.Message)"
        continue
    }

    $current = $tool.upstream.currentPin
    if ($current -eq $latest.Version -or $current -eq 'latest' -and $latest.Version -notmatch '^\d') {
        Write-Host "   $name : already at $current"
        continue
    }
    if ($current -eq $latest.Version) {
        Write-Host "   $name : up to date ($current)"
        continue
    }

    Write-Host "   $name : $current -> $($latest.Version)"

    if ($DryRun) { continue }

    $branch = "chore/bump-$name-$($latest.Version -replace '[^a-zA-Z0-9._-]','-')"
    git checkout -b $branch 2>&1 | Out-Null

    # Update currentPin in the manifest using the same JSON ordering.
    $manifestRaw = Get-Content $ManifestPath -Raw
    $manifestObj = $manifestRaw | ConvertFrom-Json
    foreach ($t in $manifestObj.tools) {
        if ($t.name -eq $name) { $t.upstream.currentPin = $latest.Version }
    }
    ($manifestObj | ConvertTo-Json -Depth 20) | Set-Content $ManifestPath -Encoding utf8

    git add $ManifestPath
    git commit -m "chore($name): bump upstream pin to $($latest.Version)" `
               -m "Previous pin: $current`nNew pin: $($latest.Version)`nRelease: $($latest.Url)" `
               -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" | Out-Null

    git push -u origin $branch 2>&1 | Out-Null

    $breaking = Test-BreakingChange -Notes $latest.Notes
    $notesExcerpt = if ($latest.Notes) { ($latest.Notes -split "`n" | Select-Object -First 20) -join "`n" } else { '(no release notes)' }

    $body = @"
Automated upstream pin bump for **$name**.

| Field | Value |
|---|---|
| Previous pin | ``$current`` |
| New pin | ``$($latest.Version)`` |
| Upstream release | $($latest.Url) |

### Release notes (excerpt)
``````
$notesExcerpt
``````
"@

    if ($breaking) {
        $wrapperPath = "modules/Invoke-$((Get-Culture).TextInfo.ToTitleCase($name) -replace '-','').ps1"
        $normPath    = "modules/normalizers/Normalize-$((Get-Culture).TextInfo.ToTitleCase($name) -replace '-','').ps1"
        $body += @"

---

> [!WARNING]
> Breaking-change heuristic matched in the release notes.
> @copilot please review ``$wrapperPath`` and ``$normPath`` and update flags / output parsing as needed.
"@
    }

    $labels = @('squad', 'enhancement', 'tool-auto-update')
    if ($breaking) { $labels += 'needs-copilot-iteration' }

    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $body -Encoding utf8
    gh pr create `
        --title "chore($name): bump upstream pin to $($latest.Version)" `
        --body-file $tmp `
        --label ($labels -join ',') `
        --head $branch `
        --base main | Out-Null
    Remove-Item $tmp

    git checkout main 2>&1 | Out-Null
}

Write-Host "Done."
