#requires -Version 7.0
<#
.SYNOPSIS
    Manifest-driven generator for the README.md tool-count facts.

.DESCRIPTION
    Reads tools/tool-manifest.json (single source of truth) and rewrites the
    auto-managed sections of README.md (between BEGIN: <id> / END: <id>
    markers) so that the user-facing tool count, feature-list count, and
    tool-catalog summary stay in lockstep with the manifest. Without this
    generator the three numbers drift on every add/remove and require a
    hand-edit on every PR.

    Three marker IDs are managed:

      tool-count-tagline
        The bold one-liner under the badges. Format:
        "**One PowerShell command, N read-only assessment tools (+ 1 opt-in),
        one unified HTML and Markdown report.** Cloud-first by default: ..."

      tool-count-feature-list
        The first bullet under the Feature highlights `details` block. Format:
        "- **N tools** (+ 1 opt-in) across Azure (...), Entra (...), GitHub
        (...), and Azure DevOps (...)."

      tool-catalog-summary
        The collapsed Tool catalog `details` summary line. Format:
        "<details><summary><b>Tool catalog (N enabled + 1 opt-in)</b></summary>"

    The "+ 1 opt-in" label is intentionally static and refers to the only
    currently-shipped opt-in tool (`copilot-triage`, `enabled: false` in the
    manifest with an explicit `-EnableAiTriage` switch). Other disabled
    manifest entries are pre-registered scaffolding for follow-up PRs and
    are not user-runnable today.

    The generator is idempotent. Running it twice on a clean tree produces
    no diff. CI uses -CheckOnly mode to fail when the committed README is
    stale relative to the manifest.

.PARAMETER ManifestPath
    Path to tools/tool-manifest.json. Defaults to the repo-relative location.

.PARAMETER ReadmePath
    Path to the root README.md. Defaults to the repo-relative location.

.PARAMETER CheckOnly
    Do not write files. Compare the generated content with what is on disk.
    Exits 0 when in sync, exits 1 when stale (and prints a clear remediation
    line).

.EXAMPLE
    pwsh -File scripts/Generate-ReadmeFacts.ps1
    Regenerate the auto-managed sections of README.md.

.EXAMPLE
    pwsh -File scripts/Generate-ReadmeFacts.ps1 -CheckOnly
    Used by CI: fail if the committed README facts are stale.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$ReadmePath,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $candidate = Split-Path -Parent $PSScriptRoot
    if (-not $candidate) { $candidate = (Get-Location).Path }
    return $candidate
}

$repoRoot = Get-RepoRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $repoRoot 'tools/tool-manifest.json' }
if (-not $ReadmePath)   { $ReadmePath   = Join-Path $repoRoot 'README.md' }

if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Manifest not found at: $ManifestPath" }
if (-not (Test-Path -LiteralPath $ReadmePath))   { throw "README.md not found at: $ReadmePath" }

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (-not $manifest.tools) { throw "Manifest at $ManifestPath has no 'tools' array." }

$enabledCount = @($manifest.tools | Where-Object { $_.enabled }).Count
if ($enabledCount -le 0) { throw "Manifest has no enabled tools; refusing to generate misleading README facts." }

# "+ 1 opt-in" is a stable marketing label for copilot-triage (the only
# currently-shipped opt-in tool, gated by -EnableAiTriage). Other disabled
# manifest entries are pre-registered futures (EASM, graph mapping family)
# that are not user-runnable yet, so they do not count here. If a second
# shipped opt-in lands, extend this expression to count tools whose `comment`
# field contains "opt-in" (or introduce an explicit `optIn: true` flag in
# the manifest schema).
$optInCount = 1

function Convert-ToLfText {
    param([string]$Text)
    return ($Text -replace "`r`n", "`n")
}

# Each section has a stable BEGIN: <id> / END: <id> marker pair. The body
# between them is regenerated verbatim from the manifest projection. To add
# a new auto-managed fact, append a new entry below and wrap the matching
# README block with the same markers.
$sections = [ordered]@{
    'tool-count-tagline' = @"
**One PowerShell command, $enabledCount read-only assessment tools (+ $optInCount opt-in), one unified HTML and Markdown report.** Cloud-first by default: target remote GitHub and Azure DevOps repositories without cloning anything by hand.
"@

    'tool-count-feature-list' = @"
- **$enabledCount tools** (+ $optInCount opt-in) across Azure (azqr, PSRule, Powerpipe, AzGovViz, Prowler, Defender for Cloud, ...), Entra (Maester, Identity Correlator, ...), GitHub (gitleaks, Trivy, Scorecard, zizmor), and Azure DevOps (pipeline security, service connections, repos).
"@

    'tool-catalog-summary' = @"
<details><summary><b>Tool catalog ($enabledCount enabled + $optInCount opt-in)</b></summary>
"@
}

$current = Convert-ToLfText (Get-Content -LiteralPath $ReadmePath -Raw)
$updated = $current

foreach ($id in $sections.Keys) {
    $beginMarker = "<!-- BEGIN: $id (generated by scripts/Generate-ReadmeFacts.ps1; do not edit by hand) -->"
    $endMarker   = "<!-- END: $id -->"

    $beginIdx = $updated.IndexOf($beginMarker)
    $endIdx   = $updated.IndexOf($endMarker)
    if ($beginIdx -lt 0 -or $endIdx -lt 0 -or $endIdx -lt $beginIdx) {
        throw "README.md is missing the BEGIN: $id / END: $id markers. Add them around the auto-managed block before running the generator."
    }

    $body = $sections[$id].TrimEnd("`n", "`r")
    $replacement = "$beginMarker`n$body`n$endMarker"
    $tail = $endIdx + $endMarker.Length
    $updated = $updated.Substring(0, $beginIdx) + $replacement + $updated.Substring($tail)
}

$updated = Convert-ToLfText $updated

if ($CheckOnly) {
    if ($current -ne $updated) {
        Write-Host "[stale] README.md auto-managed sections are out of sync with the manifest."
        Write-Host ''
        Write-Host 'Run: pwsh -File scripts/Generate-ReadmeFacts.ps1'
        exit 1
    }
    Write-Host "[ok] README.md tool-count facts in sync with manifest."
    exit 0
}

if ($current -eq $updated) {
    Write-Host "[ok] README.md tool-count facts already in sync; no write needed."
    exit 0
}

[System.IO.File]::WriteAllText($ReadmePath, $updated, [System.Text.UTF8Encoding]::new($false))
Write-Host "[wrote] $ReadmePath"
exit 0
