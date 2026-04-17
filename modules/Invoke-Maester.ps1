#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Maester — Entra ID / identity security posture assessment.
.DESCRIPTION
    Installs/imports the Maester module if needed, verifies a Microsoft Graph
    connection exists, runs Invoke-Maester -PassThru -Quiet, and returns
    findings as PSObjects. Gracefully degrades if Maester is not available,
    Graph is not connected, or the assessment fails.
    Requires: Connect-MgGraph -Scopes (Get-MtGraphScope)
.EXAMPLE
    .\Invoke-Maester.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

# Check Maester module is available (centralized Install-Prerequisites handles installation)
if (-not (Get-Module -ListAvailable -Name Maester)) {
    Write-Warning "Maester module not found. Install with: Install-Module Maester -Scope CurrentUser"
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Skipped'; Message = 'Maester module not installed. Run: Install-Module Maester -Scope CurrentUser'; Findings = @() }
}

Import-Module Maester -ErrorAction SilentlyContinue
if (-not (Get-Command Invoke-Maester -ErrorAction SilentlyContinue)) {
    Write-Warning "Maester module loaded but Invoke-Maester not found. Returning empty result."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Skipped'; Message = 'Invoke-Maester command not available'; Findings = @() }
}

# Verify Microsoft Graph connection
$mgContext = Get-MgContext -ErrorAction SilentlyContinue
if (-not $mgContext) {
    Write-Warning "No Microsoft Graph connection found. Run 'Connect-MgGraph -Scopes (Get-MtGraphScope)' before using Maester. Returning empty result."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Skipped'; Message = 'No Microsoft Graph connection. Run: Connect-MgGraph -Scopes (Get-MtGraphScope)'; Findings = @() }
}

# Run Maester assessment — returns a Pester TestResultContainer
try {
    $container = Invoke-Maester -PassThru -Quiet -ErrorAction Stop
} catch {
    Write-Warning "Maester assessment failed: $(Remove-Credentials -Text ([string]$_)). Returning empty result."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Failed'; Message = (Remove-Credentials -Text ([string]$_)); Findings = @() }
}

if (-not $container -or -not $container.Result) {
    Write-Warning "Maester returned no test results."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Failed'; Message = 'No test results returned'; Findings = @() }
}

# Map Pester TestResult objects to flat findings
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($test in $container.Result) {
    # Derive severity from tags using word boundaries so tags like
    # "criticality" or "highlight" don't bleed into Critical/High.
    $severity = 'Medium'
    if ($test.Tag) {
        $tagStr = ($test.Tag -join ' ').ToLowerInvariant()
        if     ($tagStr -match '\bcritical\b') { $severity = 'Critical' }
        elseif ($tagStr -match '\bhigh\b')     { $severity = 'High' }
        elseif ($tagStr -match '\blow\b')      { $severity = 'Low' }
        elseif ($tagStr -match '\b(info|informational)\b') { $severity = 'Info' }
    }

    # Map Result: Passed/Skipped/NotRun → compliant, Failed → non-compliant
    $compliant = $test.Result -ne 'Failed'

    # Extract detail from ErrorRecord if present
    $detail = ''
    if ($test.ErrorRecord) {
        $detail = ($test.ErrorRecord | ForEach-Object { $_.ToString() }) -join '; '
    }

    # Extract category from parent Block name
    $category = 'Identity'
    if ($test.Block -and $test.Block.Name) {
        $category = $test.Block.Name
    }

    $findings.Add([PSCustomObject]@{
        Id           = [guid]::NewGuid().ToString()
        Category     = $category
        Title        = $test.Name ?? 'Unknown'
        Severity     = $severity
        Compliant    = $compliant
        Detail       = $detail
        Remediation  = ''
        ResourceId   = ''
        LearnMoreUrl = ''
    })
}

return [PSCustomObject]@{ Source = 'maester'; Status = 'Success'; Message = ''; Findings = $findings }
