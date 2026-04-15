#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for OpenSSF Scorecard CLI.
.DESCRIPTION
    Runs the scorecard CLI against a GitHub repository and returns supply chain
    security findings as PSObjects. If scorecard is not installed, writes a
    warning and returns an empty result.
    Never throws — designed for graceful degradation in the orchestrator.
.PARAMETER Repository
    The repository to scan (e.g., "github.com/martinopedal/azure-analyzer").
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Repository
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ScorecardInstalled {
    $null -ne (Get-Command scorecard -ErrorAction SilentlyContinue)
}

if (-not (Test-ScorecardInstalled)) {
    Write-Warning "scorecard is not installed. Skipping Scorecard scan. Install from https://github.com/ossf/scorecard/releases"
    return [PSCustomObject]@{
        Source   = 'scorecard'
        Findings = @()
    }
}

try {
    Write-Verbose "Running scorecard for repository $Repository"
    $rawOutput = scorecard --repo=$Repository --format=json 2>&1
    $json = $rawOutput | Out-String | ConvertFrom-Json -ErrorAction Stop

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $repoName = ''
    if ($json.repo -and $json.repo.name) {
        $repoName = $json.repo.name
    }

    if ($json.checks) {
        foreach ($check in $json.checks) {
            $score = [int]$check.score

            # Skip checks that were not evaluated
            if ($score -eq -1) { continue }

            # Map score to severity: 0-3=High, 4-6=Medium, 7-9=Low, 10=Info
            $severity = switch ($score) {
                { $_ -le 3 } { 'High' }
                { $_ -le 6 } { 'Medium' }
                { $_ -le 9 } { 'Low' }
                default      { 'Info' }
            }

            $learnMoreUrl = ''
            if ($check.documentation -and $check.documentation.url) {
                $learnMoreUrl = $check.documentation.url
            }

            $findings.Add([PSCustomObject]@{
                Id           = [guid]::NewGuid().ToString()
                Category     = 'Supply Chain'
                Title        = $check.name ?? 'Unknown'
                Severity     = $severity
                Compliant    = $score -ge 7
                Detail       = $check.reason ?? ''
                Remediation  = ''
                ResourceId   = $repoName
                LearnMoreUrl = $learnMoreUrl
            })
        }
    }

    return [PSCustomObject]@{
        Source   = 'scorecard'
        Findings = $findings
    }
} catch {
    Write-Warning "Scorecard scan failed: $_"
    return [PSCustomObject]@{
        Source   = 'scorecard'
        Findings = @()
    }
}
