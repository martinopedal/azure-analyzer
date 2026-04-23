#Requires -Version 7.0
<#
.SYNOPSIS
    Optional AI triage enrichment using the GitHub Copilot SDK.
.DESCRIPTION
    Checks prerequisites (Python 3.10+, github-copilot-sdk, Copilot-scoped token),
    then calls the Python triage script. Never throws — returns $null on any failure
    so the main pipeline continues without AI enrichment.
    Requires a GitHub Copilot license (Individual, Business, or Enterprise).
#>
[CmdletBinding()]
param(
    [string] $InputPath = (Join-Path $PSScriptRoot '..' 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '..' 'output' 'triage.json')
)
Set-StrictMode -Version Latest

# --- Check 1: Python 3.10+ ---
$py = $null
try {
    $v = & python3 --version 2>&1
    if ($LASTEXITCODE -eq 0 -and $v -match 'Python (\d+)\.(\d+)' -and [int]$Matches[1] -ge 3 -and [int]$Matches[2] -ge 10) {
        $py = 'python3'
    }
} catch { } # best-effort: python3 not on PATH; fall through to 'python'
if (-not $py) {
    try {
        $v = & python --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $v -match 'Python (\d+)\.(\d+)' -and [int]$Matches[1] -ge 3 -and [int]$Matches[2] -ge 10) {
            $py = 'python'
        }
    } catch { } # best-effort: python interpreter unavailable; handled by Write-Warning below
}
if (-not $py) {
    Write-Warning 'AI triage requires Python 3.10+. Skipping.'
    return $null
}

# --- Check 2: github-copilot-sdk installed ---
try {
    & $py -c 'import copilot' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Warning 'AI triage requires github-copilot-sdk. Install with: pip install github-copilot-sdk. Skipping.'
    return $null
}

# --- Check 3: Copilot token available ---
$tk = $env:COPILOT_GITHUB_TOKEN
if (-not $tk) { $tk = $env:GH_TOKEN }
if (-not $tk) { $tk = $env:GITHUB_TOKEN }
if (-not $tk) {
    Write-Warning "AI triage requires a GitHub Copilot license. Set COPILOT_GITHUB_TOKEN with a PAT that has the 'copilot' scope. Skipping."
    return $null
}
if ($tk.StartsWith('ghs_')) {
    Write-Warning "AI triage does not support GitHub Actions tokens (ghs_). Use a PAT with the 'copilot' scope. Skipping."
    return $null
}

# --- Validate inputs ---
if (-not (Test-Path $InputPath)) {
    Write-Warning "AI triage: input file not found — $InputPath. Skipping."
    return $null
}
$scriptPath = Join-Path $PSScriptRoot 'Invoke-CopilotTriage.py'
if (-not (Test-Path $scriptPath)) {
    Write-Warning 'AI triage: Python script not found. Skipping.'
    return $null
}

# --- Run triage ---
Write-Host ''
Write-Host '  ⚠ DATA NOTICE: Non-compliant finding data (titles, details, resource IDs)' -ForegroundColor Yellow
Write-Host '    will be sent to GitHub Copilot services for AI analysis.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Running AI triage enrichment...' -ForegroundColor Magenta
try {
    & $py $scriptPath --input $InputPath --output $OutputPath 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "AI triage: Python script exited with code $LASTEXITCODE. Skipping."
        return $null
    }
    if (-not (Test-Path $OutputPath)) {
        Write-Warning 'AI triage: triage.json was not created. Skipping.'
        return $null
    }
    $triage = Get-Content $OutputPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host "AI triage complete — enriched findings written to $OutputPath" -ForegroundColor Green
    return $triage
} catch {
    Write-Warning "AI triage: unexpected error — $_. Skipping."
    return $null
}
