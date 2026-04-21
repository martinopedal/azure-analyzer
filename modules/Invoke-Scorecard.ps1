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
.PARAMETER GitHubHost
    Custom GitHub host for GHEC-DR or GHES (e.g., "github.contoso.com").
    Sets GH_HOST environment variable for the scorecard CLI call.
    When empty, defaults to github.com.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Repository,

    [ValidateRange(0, 10)]
    [int] $Threshold = 7,

    [string] $GitHubHost = 'github.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

function Test-ScorecardInstalled {
    $null -ne (Get-Command scorecard -ErrorAction SilentlyContinue)
}

function ConvertTo-StringArray {
    param ([object] $InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [string]) { return @([string]$InputObject) }

    $output = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $output.Add($text.Trim())
        }
    }
    return $output.ToArray()
}

function Get-ScorecardVersionData {
    $toolVersion = ''
    $releaseTag = ''

    try {
        $rawVersion = scorecard --version 2>&1 | Out-String
        $toolVersion = $rawVersion.Trim()
        if ($toolVersion -match '(v\d+\.\d+(?:\.\d+)?)') {
            $releaseTag = $matches[1]
        }
    } catch {
        Write-Verbose "Unable to read scorecard version: $($_.Exception.Message)"
    }

    return @{
        ToolVersion  = $toolVersion
        ReleaseTag   = $releaseTag
        BaselineTags = if ($releaseTag) { @($releaseTag) } else { @() }
    }
}

function Get-ObjectPropertyValue {
    param (
        [object] $Object,
        [string] $PropertyName
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($PropertyName)) { return $null }

    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($PropertyName)) {
        return $Object[$PropertyName]
    }

    $property = $Object | Get-Member -Name $PropertyName -MemberType NoteProperty, Property -ErrorAction SilentlyContinue
    if ($property) {
        return $Object.$PropertyName
    }

    return $null
}

function ConvertTo-ScorecardCheckSlug {
    param ([string] $CheckName)

    if ([string]::IsNullOrWhiteSpace($CheckName)) { return '' }
    $slug = $CheckName.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    return $slug.Trim('-')
}

function Get-ScorecardDeepLinkUrl {
    param ([string] $CheckName)
    $slug = ConvertTo-ScorecardCheckSlug -CheckName $CheckName
    if (-not $slug) { return '' }
    return "https://github.com/ossf/scorecard/blob/main/docs/checks.md#$slug"
}

function Get-ScorecardSeverityFromScore {
    param ([int] $Score)

    if ($Score -eq -1) { return 'Info' }
    if ($Score -le 2) { return 'Critical' }
    if ($Score -le 5) { return 'High' }
    if ($Score -le 7) { return 'Medium' }
    if ($Score -le 9) { return 'Low' }
    return 'Info'
}

function Get-ScorecardCategory {
    param ([string] $CheckName)

    $normalized = (ConvertTo-ScorecardCheckSlug -CheckName $CheckName)
    $mappedCategory = switch ($normalized) {
        'maintained'             { 'Maintained' }
        'code-review'            { 'Code-Review' }
        'sast'                   { 'SAST' }
        'dependencies'           { 'Dependencies' }
        'pinned-dependencies'    { 'Dependencies' }
        'branch-protection'      { 'Code-Review' }
        'security-policy'        { 'Security-Policy' }
        'token-permissions'      { 'Token-Permissions' }
        'signed-releases'        { 'Signed-Releases' }
        'dangerous-workflow'     { 'Dangerous-Workflow' }
        'binary-artifacts'       { 'Binary-Artifacts' }
        'packaging'              { 'Packaging' }
        default                  { 'Supply Chain' }
    }
    return $mappedCategory
}

function Get-ScorecardFrameworks {
    param ([string] $CheckName)

    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    $frameworks.Add(@{
        Name     = 'OpenSSF Scorecard'
        Controls = @($CheckName)
    })

    $slsaControlMap = @{
        'binary-artifacts'   = @('Build L3', 'Provenance L3')
        'branch-protection'  = @('Source L3')
        'code-review'        = @('Source L3')
        'ci-tests'           = @('Build L3')
        'packaging'          = @('Provenance L3')
        'pinned-dependencies'= @('Build L3')
        'signed-releases'    = @('Provenance L3')
        'token-permissions'  = @('Build L3')
    }

    $normalized = ConvertTo-ScorecardCheckSlug -CheckName $CheckName
    if ($slsaControlMap.ContainsKey($normalized)) {
        $frameworks.Add(@{
            Name     = 'SLSA'
            Controls = @($slsaControlMap[$normalized])
        })
    }

    return $frameworks.ToArray()
}

function Get-ScorecardRemediationSnippets {
    param ([object] $Documentation)

    if ($null -eq $Documentation) { return @() }

    $snippets = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($propertyName in @('text', 'short', 'details', 'remediation')) {
        $value = [string](Get-ObjectPropertyValue -Object $Documentation -PropertyName $propertyName)
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $snippets.Add(@{
            Kind    = 'Documentation'
            Title   = $propertyName
            Content = $value.Trim()
        })
    }

    return $snippets.ToArray()
}

if (-not (Test-ScorecardInstalled)) {
    Write-Warning "scorecard is not installed. Skipping Scorecard scan. Install from https://github.com/ossf/scorecard/releases"
    return [PSCustomObject]@{
        Source   = 'scorecard'
        SchemaVersion = '1.0'
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
    $versionData = Get-ScorecardVersionData

    # Set GH_HOST for GHEC-DR / GHES, preserving the original value
    $originalGhHost = $env:GH_HOST
    if ($GitHubHost) {
        Write-Verbose "Setting GH_HOST=$GitHubHost for enterprise GitHub instance"
        $env:GH_HOST = $GitHubHost
    }

    try {
        Write-Verbose "Running scorecard for repository $Repository (threshold=$Threshold)"
        # Real scorecard CLIs are external binaries; Pester mocks register it as a PS function.
        # For external binaries, run under a hard 300s Start-Job / Wait-Job timeout.
        # For functions/cmdlets (tests), call directly — no hang risk and Start-Job can't see in-process mocks.
        $scCmd = Get-Command scorecard -ErrorAction SilentlyContinue
        if ($scCmd -and $scCmd.CommandType -eq 'Application') {
            $scorecardJob = Start-Job -ScriptBlock {
                param($repo, $ghHost)
                if ($ghHost) { $env:GH_HOST = $ghHost }
                scorecard --repo=$repo --format=json 2>&1
            } -ArgumentList $Repository, $GitHubHost
            if (Wait-Job -Job $scorecardJob -Timeout 300) {
                $rawOutput = Receive-Job -Job $scorecardJob
            } else {
                Stop-Job -Job $scorecardJob -ErrorAction SilentlyContinue
                Remove-Job -Job $scorecardJob -Force -ErrorAction SilentlyContinue
                throw "scorecard CLI timed out after 300 seconds for repo $Repository"
            }
            Remove-Job -Job $scorecardJob -Force -ErrorAction SilentlyContinue
        } else {
            $rawOutput = scorecard --repo=$Repository --format=json 2>&1
        }
        $json = $rawOutput | Out-String | ConvertFrom-Json -ErrorAction Stop
    } finally {
        # Restore original GH_HOST
        if ($GitHubHost) {
            if ($null -eq $originalGhHost) {
                Remove-Item Env:\GH_HOST -ErrorAction SilentlyContinue
            } else {
                $env:GH_HOST = $originalGhHost
            }
        }
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $repoName = ($Repository -replace '^https?://', '').Trim('/').ToLowerInvariant()
    if ($json.repo -and $json.repo.name) {
        $repoValue = ([string]$json.repo.name).Trim('/').ToLowerInvariant()
        if ($repoValue -match '^[^/]+/[^/]+$') {
            $repoName = "$($GitHubHost.ToLowerInvariant())/$repoValue"
        } elseif ($repoValue -match '^[^/]+\.[^/]+/[^/]+/[^/]+$') {
            $repoName = $repoValue
        }
    }

    if ($json.checks) {
        foreach ($check in $json.checks) {
            $score = -1
            $rawScore = Get-ObjectPropertyValue -Object $check -PropertyName 'score'
            if ($null -ne $rawScore) {
                $parsedScore = 0
                if ([int]::TryParse([string]$rawScore, [ref]$parsedScore)) {
                    $score = $parsedScore
                }
            }

            $checkName = if ($check.name) { [string]$check.name } else { 'Unknown' }
            $severity = Get-ScorecardSeverityFromScore -Score $score
            $compliant = ($score -ge $Threshold) -and ($score -ge 0)
            $reason = if ($check.reason) { [string]$check.reason } else { '' }
            $detail = if ([string]::IsNullOrWhiteSpace($reason)) {
                "Score $score/10."
            } else {
                "Score $score/10. $reason"
            }
            $deepLinkUrl = Get-ScorecardDeepLinkUrl -CheckName $checkName
            $documentationUrl = Get-ObjectPropertyValue -Object $check.documentation -PropertyName 'url'
            $learnMoreUrl = if ($documentationUrl) {
                [string]$documentationUrl
            } else {
                $deepLinkUrl
            }
            $remediationSnippets = Get-ScorecardRemediationSnippets -Documentation $check.documentation
            $remediation = ''
            if (@($remediationSnippets).Count -gt 0) {
                $firstSnippet = $remediationSnippets[0]
                if ($firstSnippet -is [System.Collections.IDictionary] -and $firstSnippet.Contains('Content')) {
                    $remediation = [string]$firstSnippet['Content']
                } elseif ($null -ne (Get-ObjectPropertyValue -Object $firstSnippet -PropertyName 'Content')) {
                    $remediation = [string]$firstSnippet.Content
                }
            }
            $checkDetails = ConvertTo-StringArray -InputObject $check.details

            $findings.Add([PSCustomObject]@{
                Id                  = [guid]::NewGuid().ToString()
                Category            = Get-ScorecardCategory -CheckName $checkName
                Title               = $checkName
                Severity            = $severity
                Compliant           = $compliant
                Detail              = $detail
                Remediation         = $remediation
                ResourceId          = $repoName
                LearnMoreUrl        = $learnMoreUrl
                Score               = $score
                CheckName           = $checkName
                CheckDetails        = $checkDetails
                Frameworks          = Get-ScorecardFrameworks -CheckName $checkName
                Pillar              = 'Security'
                DeepLinkUrl         = $deepLinkUrl
                RemediationSnippets = $remediationSnippets
                BaselineTags        = @($versionData.BaselineTags)
                ToolVersion         = [string]$versionData.ToolVersion
            })
        }
    }

    return [PSCustomObject]@{
        Source   = 'scorecard'
        SchemaVersion = '1.0'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning "Scorecard scan failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'scorecard'
        SchemaVersion = '1.0'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
    }
}
