#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Maester — Entra ID / identity security posture assessment.
.DESCRIPTION
    Installs/imports the Maester module if needed, verifies a Microsoft Graph
    connection exists, runs Invoke-Maester -PassThru -Quiet, and returns
    findings as PSObjects. Gracefully degrades if Maester is not available,
    Graph is not connected, or the assessment fails.
.EXAMPLE
    .\Invoke-Maester.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

# Ensure Maester module is available
if (-not (Get-Module -ListAvailable -Name Maester)) {
    try {
        Write-Warning "Maester module not found. Installing from PSGallery..."
        Install-Module -Name Maester -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        Write-Warning "Could not install Maester module: $_. Returning empty result."
        return [PSCustomObject]@{ Source = 'maester'; Status = 'Skipped'; Message = 'Could not install Maester module'; Findings = @() }
    }
}

Import-Module Maester -ErrorAction SilentlyContinue
if (-not (Get-Command Invoke-Maester -ErrorAction SilentlyContinue)) {
    Write-Warning "Maester module loaded but Invoke-Maester not found. Returning empty result."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Skipped'; Message = 'Could not install Maester module'; Findings = @() }
}

# Verify Microsoft Graph connection
$mgContext = Get-MgContext -ErrorAction SilentlyContinue
if (-not $mgContext) {
    Write-Warning "No Microsoft Graph connection found. Run Connect-MgGraph before using Maester. Returning empty result."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Skipped'; Message = 'No Microsoft Graph connection'; Findings = @() }
}

# Run Maester assessment
try {
    $result = Invoke-Maester -PassThru -Quiet -ErrorAction Stop
} catch {
    Write-Warning "Maester assessment failed: $_. Returning empty result."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Failed'; Message = "$_"; Findings = @() }
}

if (-not $result -or -not $result.Tests) {
    Write-Warning "Maester returned no test results."
    return [PSCustomObject]@{ Source = 'maester'; Status = 'Failed'; Message = 'No test results returned'; Findings = @() }
}

# Map tests to flat finding objects
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($test in $result.Tests) {
    # Derive severity from tags (default to Medium)
    $severity = 'Medium'
    if ($test.Tag) {
        $tagStr = ($test.Tag -join ' ').ToLowerInvariant()
        if ($tagStr -match 'critical|high') { $severity = 'High' }
        elseif ($tagStr -match 'low') { $severity = 'Low' }
    }

    # Map Result to Compliant: Passed/Skipped → true, Failed → false
    $compliant = $test.Result -ne 'Failed'

    # Extract detail from ErrorRecord if present
    $detail = ''
    if ($test.ErrorRecord) {
        $detail = ($test.ErrorRecord | ForEach-Object { $_.ToString() }) -join '; '
    }

    # Extract category from Block.Name
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
