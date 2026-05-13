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

$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }

# Bootstrap Invoke-WithTimeout for CLI timeout protection.
# Lazy-load pattern (matches modules/shared/RemoteClone.ps1): we do NOT dot-source
# CliTimeout.ps1 at module top, because that would shadow Pester `Mock Invoke-WithTimeout`
# calls in tests (the dot-source binds the real implementation into this script's scope,
# taking precedence over outer-scope mocks). Instead the real implementation is loaded
# just-in-time inside the try block, only when no command of that name is already in scope
# (i.e. no test mock active).
$script:invokeWithTimeoutIsFallback = $false
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param (
            [Parameter(Mandatory)][string]$Command,
            [Parameter(Mandatory)][string[]]$Arguments,
            [int]$TimeoutSec = 300
        )
        $output = & $Command @Arguments 2>&1 | Out-String
        [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = Remove-Credentials $output
        }
    }
    $script:invokeWithTimeoutIsFallback = $true
}

$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details; TimestampUtc=(Get-Date).ToUniversalTime().ToString('o') } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
}

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
    return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Skipped' -Message 'Python 3.10+ not available'
}

# --- Check 2: github-copilot-sdk installed ---
try {
    & $py -c 'import copilot' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Warning 'AI triage requires github-copilot-sdk. Install with: pip install github-copilot-sdk. Skipping.'
    return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Skipped' -Message 'github-copilot-sdk not installed'
}

# --- Check 3: Copilot token available ---
$tk = $env:COPILOT_GITHUB_TOKEN
if (-not $tk) { $tk = $env:GH_TOKEN }
if (-not $tk) { $tk = $env:GITHUB_TOKEN }
if (-not $tk) {
    Write-Warning "AI triage requires a GitHub Copilot license. Set COPILOT_GITHUB_TOKEN with a PAT that has the 'copilot' scope. Skipping."
    return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Skipped' -Message 'No Copilot token'
}
if ($tk.StartsWith('ghs_')) {
    Write-Warning "AI triage does not support GitHub Actions tokens (ghs_). Use a PAT with the 'copilot' scope. Skipping."
    return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Skipped' -Message 'GitHub Actions tokens not supported'
}

# --- Validate inputs ---
if (-not (Test-Path $InputPath)) {
    Write-Warning "AI triage: input file not found — $InputPath. Skipping."
    return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Skipped' -Message 'Input file not found'
}
$scriptPath = Join-Path $PSScriptRoot 'Invoke-CopilotTriage.py'
if (-not (Test-Path $scriptPath)) {
    Write-Warning 'AI triage: Python script not found. Skipping.'
    return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Skipped' -Message 'Python script not found'
}

# --- Run triage ---
Write-Host ''
Write-Host '  ⚠ DATA NOTICE: Non-compliant finding data (titles, details, resource IDs)' -ForegroundColor Yellow
Write-Host '    will be sent to GitHub Copilot services for AI analysis.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Running AI triage enrichment...' -ForegroundColor Magenta
try {
    # Lazy-load real Invoke-WithTimeout (CliTimeout.ps1) only if we have just our own
    # fallback in scope; never dot-source over an active Pester mock.
    if ($script:invokeWithTimeoutIsFallback) {
        $cliTimeoutPath = Join-Path $PSScriptRoot 'shared' 'CliTimeout.ps1'
        if (Test-Path $cliTimeoutPath) {
            . $cliTimeoutPath
            $script:invokeWithTimeoutIsFallback = $false
        }
    }

    $args = @($scriptPath, '--input', $InputPath, '--output', $OutputPath)
    $result = Invoke-WithTimeout -Command $py -Arguments $args -TimeoutSec 300
    
    if ($result.ExitCode -eq -1) {
        Write-Warning 'AI triage: Python subprocess timed out after 300s. Skipping.'
        $err = New-FindingError -Source 'wrapper:copilot-triage' `
            -Category 'TimeoutExceeded' `
            -Reason 'Python triage subprocess timed out after 300 seconds.' `
            -Remediation 'Reduce finding count or check for network issues; re-run with -Verbose for detail.' `
            -Details (Remove-Credentials $result.Output)
        return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Failed' -Message 'Python subprocess timed out' -FindingErrors @($err)
    }
    
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $result.Output -split "`n" | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                Write-Host "  $_" -ForegroundColor DarkGray
            }
        }
    }
    
    if ($result.ExitCode -ne 0) {
        Write-Warning "AI triage: Python script exited with code $($result.ExitCode). Skipping."
        return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Failed' -Message "Python script exited with non-zero"
    }
    if (-not (Test-Path $OutputPath)) {
        Write-Warning 'AI triage: triage.json was not created. Skipping.'
        return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Failed' -Message 'triage.json not created'
    }
    $triage = Get-Content $OutputPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host "AI triage complete — enriched findings written to $OutputPath" -ForegroundColor Green
    return $triage
} catch {
    # Keep PR-author-visible Message generic to avoid leaking exception text
    # (paths, resource IDs, partial command lines). Sanitize and write the full
    # detail to the warning stream / Errors envelope where it belongs.
    $details = Remove-Credentials ([string]$_)
    Write-Warning "AI triage: unexpected error. Skipping. $details"
    $err = [PSCustomObject]@{
        Source       = 'wrapper:copilot-triage'
        Category     = 'UnexpectedFailure'
        Reason       = 'Unexpected error during AI triage subprocess'
        Remediation  = 'Re-run with -Verbose; inspect Python script logs for the underlying cause.'
        Details      = $details
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    return New-WrapperEnvelope -Source 'copilot-triage' -Status 'Failed' -Message 'Unexpected error during AI triage' -FindingErrors @($err)
}
