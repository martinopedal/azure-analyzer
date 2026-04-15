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
.PARAMETER Threshold
    Minimum score (0-10) to consider a check compliant. Default is 7.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Repository,

    [ValidateRange(0, 10)]
    [int] $Threshold = 7
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
        Status   = 'Skipped'
        Message  = 'scorecard CLI not installed. Download from https://github.com/ossf/scorecard/releases'
        Findings = @()
    }
}

# Warn if no GitHub auth token is set (authenticated requests get higher rate limits)
if (-not $env:GITHUB_AUTH_TOKEN -and -not $env:GITHUB_TOKEN) {
    Write-Warning "Neither GITHUB_AUTH_TOKEN nor GITHUB_TOKEN is set. Scorecard will use unauthenticated requests (lower rate limits)."
}

try {
    Write-Verbose "Running scorecard for repository $Repository (threshold=$Threshold)"
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

            if ($score -eq -1) {
                # score = -1 means the check errored/failed to run — treat as non-compliant
                $severity  = 'High'
                $compliant = $false
                $detail    = "Check failed to run"
                if ($check.reason) { $detail += ": $($check.reason)" }
            } else {
                # Map score to severity: 0-3=High, 4-6=Medium, 7-9=Low, 10=Info
                $severity = switch ($score) {
                    { $_ -le 3 } { 'High' }
                    { $_ -le 6 } { 'Medium' }
                    { $_ -le 9 } { 'Low' }
                    default      { 'Info' }
                }
                $compliant = $score -ge $Threshold
                $detail    = $check.reason ?? ''
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
                Compliant    = $compliant
                Detail       = "$detail (score $score/10)"
                Remediation  = ''
                ResourceId   = $repoName
                LearnMoreUrl = $learnMoreUrl
            })
        }
    }

    return [PSCustomObject]@{
        Source   = 'scorecard'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning "Scorecard scan failed: $_"
    return [PSCustomObject]@{
        Source   = 'scorecard'
        Status   = 'Failed'
        Message  = "$_"
        Findings = @()
    }
}
