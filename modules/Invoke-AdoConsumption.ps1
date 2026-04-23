#Requires -Version 7.4
<#
.SYNOPSIS
    Azure DevOps pipeline consumption telemetry.
.DESCRIPTION
    Collects build run duration and reliability signals from Azure DevOps REST APIs.
    Emits v1 findings for project share of org runner minutes, duration regression,
    and failed build rate.
.PARAMETER AdoOrg
    Azure DevOps organization name.
.PARAMETER AdoProject
    Optional project filter. When omitted, all projects in the organization are scanned.
.PARAMETER DaysBack
    Lookback window in days. Defaults to 30.
.PARAMETER MonthlyBudgetUsd
    Optional soft budget threshold for estimated paid minute cost.
.PARAMETER AdoPat
    ADO PAT token. Falls back to ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, AZ_DEVOPS_PAT.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [Alias('Organization')]
    [ValidateNotNullOrEmpty()]
    [string] $AdoOrg,

    [Alias('Project')]
    [string] $AdoProject,

    [ValidateRange(1, 365)]
    [int] $DaysBack = 30,

    [double] $MonthlyBudgetUsd,

    [Alias('AdoPatToken')]
    [string] $AdoPat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = Join-Path $PSScriptRoot 'shared'
. (Join-Path $sharedDir 'Retry.ps1')
. (Join-Path $sharedDir 'Sanitize.ps1')

function Resolve-AdoPat {
    param ([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ADO_PAT_TOKEN) { return $env:ADO_PAT_TOKEN }
    if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
    if ($env:AZ_DEVOPS_PAT) { return $env:AZ_DEVOPS_PAT }
    return $null
}

function Invoke-AdoApi {
    param (
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [hashtable] $Headers
    )

    Invoke-WithRetry -ScriptBlock {
        $webResponse = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -ContentType 'application/json'
        $bodyText = [string]$webResponse.Content
        $body = if ([string]::IsNullOrWhiteSpace($bodyText)) {
            [PSCustomObject]@{}
        } else {
            $bodyText | ConvertFrom-Json -Depth 100
        }

        $continuationToken = $null
        if ($webResponse.Headers -and $webResponse.Headers.ContainsKey('x-ms-continuationtoken')) {
            $tokenValue = $webResponse.Headers['x-ms-continuationtoken']
            if ($tokenValue -is [array]) { $continuationToken = $tokenValue[0] } else { $continuationToken = $tokenValue }
        }

        [PSCustomObject]@{
            Body = $body
            ContinuationToken = $continuationToken
        }
    }
}

function Get-AdoPagedValues {
    param (
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [hashtable] $Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $continuationToken = $null
    do {
        $pagedUri = $Uri
        if ($continuationToken) {
            $separator = if ($pagedUri -like '*?*') { '&' } else { '?' }
            $pagedUri += "$separator" + 'continuationToken=' + [uri]::EscapeDataString([string]$continuationToken)
        }

        $response = Invoke-AdoApi -Uri $pagedUri -Headers $Headers
        $body = if ($response) { $response.Body } else { $null }
        if ($body -and $body.PSObject.Properties['value']) {
            foreach ($item in @($body.value)) { $items.Add($item) }
        }
        $continuationToken = if ($response) { $response.ContinuationToken } else { $null }
    } while ($continuationToken)

    return @($items)
}

function Get-AdoProjects {
    param (
        [Parameter(Mandatory)]
        [string] $Org,
        [Parameter(Mandatory)]
        [hashtable] $Headers
    )

    $orgEnc = [uri]::EscapeDataString($Org)
    $uri = "https://dev.azure.com/$orgEnc/_apis/projects?api-version=7.1&`$top=200"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-ProjectBuilds {
    param (
        [Parameter(Mandatory)]
        [string] $Org,
        [Parameter(Mandatory)]
        [string] $ProjectName,
        [Parameter(Mandatory)]
        [datetime] $SinceUtc,
        [Parameter(Mandatory)]
        [hashtable] $Headers
    )

    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($ProjectName)
    $minTime = [uri]::EscapeDataString($SinceUtc.ToString('o'))
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/build/builds?api-version=7.1&queryOrder=finishTimeDescending&minTime=$minTime&`$top=200"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-BuildDurationMinutes {
    param ([Parameter(Mandatory)][psobject]$Build)
    if (-not $Build.PSObject.Properties['startTime'] -or -not $Build.startTime) { return 0.0 }
    if (-not $Build.PSObject.Properties['finishTime'] -or -not $Build.finishTime) { return 0.0 }
    try {
        $start = [datetime]$Build.startTime
        $finish = [datetime]$Build.finishTime
        if ($finish -le $start) { return 0.0 }
        return [math]::Round(($finish - $start).TotalMinutes, 2)
    } catch {
        return 0.0
    }
}

function Get-AdoToolVersion {
    try {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return '' }
        $raw = az devops --version 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        $text = if ($raw -is [array]) { ($raw -join ' ') } else { [string]$raw }
        $match = [regex]::Match($text, '(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9\.-]+)?)')
        if ($match.Success) { return $match.Groups[1].Value }
        return $text.Trim()
    } catch {
        return ''
    }
}

function Resolve-ProjectTier {
    param ([double]$SharePercent)
    if ($SharePercent -gt 50.0) { return 'Tier1' }
    if ($SharePercent -gt 20.0) { return 'Tier2' }
    return 'Tier3'
}

function Resolve-Impact {
    param (
        [double]$FailRate,
        [double]$SharePercent,
        [double]$BudgetPercent
    )
    if ($FailRate -gt 25.0 -or $SharePercent -gt 50.0 -or $BudgetPercent -gt 150.0) { return 'High' }
    if ($FailRate -gt 10.0 -or $SharePercent -gt 30.0 -or $BudgetPercent -gt 110.0) { return 'Medium' }
    return 'Low'
}

$pat = Resolve-AdoPat -Explicit $AdoPat
if (-not $pat) {
    return [PSCustomObject]@{
        Source   = 'ado-consumption'
        Status   = 'Skipped'
        Message  = 'No ADO PAT provided. Set -AdoPat, ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.'
        Findings = @()
    }    Errors   = @()
$3
}

$pair = ":$pat"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$headers = @{ Authorization = "Basic $base64" }

try {
    $sinceUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $DaysBack)
    $toolVersion = Get-AdoToolVersion
    $projects = @()
    if ($AdoProject) {
        $projects = @([PSCustomObject]@{ name = $AdoProject })
    } else {
        $projects = @(Get-AdoProjects -Org $AdoOrg -Headers $headers)
    }

    if ($projects.Count -eq 0) {
        return [PSCustomObject]@{
            Source   = 'ado-consumption'
            Status   = 'Success'
            Message  = "No projects found in organization '$AdoOrg'."
            Findings = @()
        }    Errors   = @()
$3
    }

    $projectStats = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($projectObj in $projects) {
        $projectName = if ($projectObj.PSObject.Properties['name'] -and $projectObj.name) { [string]$projectObj.name } else { '' }
        if (-not $projectName) { continue }
        $builds = @(Get-ProjectBuilds -Org $AdoOrg -ProjectName $projectName -SinceUtc $sinceUtc -Headers $headers)

        $minutes = [System.Collections.Generic.List[double]]::new()
        $failed = 0
        $nowUtc = (Get-Date).ToUniversalTime()
        $midpointUtc = $sinceUtc.AddTicks([int64](($nowUtc - $sinceUtc).Ticks / 2))
        $firstHalf = [System.Collections.Generic.List[double]]::new()
        $secondHalf = [System.Collections.Generic.List[double]]::new()
        $pipelineDefinitionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $pipelineEvidenceUris = [System.Collections.Generic.List[string]]::new()

        foreach ($build in $builds) {
            $duration = Get-BuildDurationMinutes -Build $build
            if ($duration -gt 0) {
                $minutes.Add($duration)
            }

            $resultValue = if ($build.PSObject.Properties['result'] -and $build.result) { [string]$build.result } else { '' }
            if ($resultValue -match '^(?i)failed$') {
                $failed++
            }

            if ($build.PSObject.Properties['finishTime'] -and $build.finishTime -and $duration -gt 0) {
                try {
                    $finishUtc = ([datetime]$build.finishTime).ToUniversalTime()
                    if ($finishUtc -lt $midpointUtc) { $firstHalf.Add($duration) } else { $secondHalf.Add($duration) }
                } catch {
                    continue
                }
            }

            $definitionId = ''
            if ($build.PSObject.Properties['definition'] -and $build.definition -and $build.definition.PSObject.Properties['id'] -and $build.definition.id) {
                $definitionId = [string]$build.definition.id
            } elseif ($build.PSObject.Properties['definitionId'] -and $build.definitionId) {
                $definitionId = [string]$build.definitionId
            }
            if (-not [string]::IsNullOrWhiteSpace($definitionId) -and $pipelineDefinitionIds.Add($definitionId)) {
                $pipelineEvidenceUris.Add("https://dev.azure.com/$AdoOrg/$projectName/_build?definitionId=$definitionId&view=results&_a=analytics") | Out-Null
            }
        }

        $totalRuns = $builds.Count
        $totalMinutes = if ($minutes.Count -gt 0) { [math]::Round(($minutes | Measure-Object -Sum).Sum, 2) } else { 0.0 }
        $firstAvg = if ($firstHalf.Count -gt 0) { [math]::Round(($firstHalf | Measure-Object -Average).Average, 2) } else { 0.0 }
        $secondAvg = if ($secondHalf.Count -gt 0) { [math]::Round(($secondHalf | Measure-Object -Average).Average, 2) } else { 0.0 }
        $failRate = if ($totalRuns -gt 0) { [math]::Round((100.0 * $failed / $totalRuns), 2) } else { 0.0 }

        $projectStats.Add([PSCustomObject]@{
                Project      = $projectName
                TotalRuns    = $totalRuns
                FailedRuns   = $failed
                TotalMinutes = $totalMinutes
                FirstAvg     = $firstAvg
                SecondAvg    = $secondAvg
                FailRate     = $failRate
                DefinitionIds = @($pipelineDefinitionIds)
                PipelineEvidenceUris = @($pipelineEvidenceUris)
            })
    }

    $orgTotalMinutes = [math]::Round((@($projectStats | Measure-Object TotalMinutes -Sum).Sum), 2)
    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($stat in $projectStats) {
        $projectId = "ado://$($AdoOrg.ToLowerInvariant())/$($stat.Project.ToLowerInvariant())"
        $projectDashboard = "https://dev.azure.com/$AdoOrg/$($stat.Project)/_build"
        $projectAnalytics = "https://dev.azure.com/$AdoOrg/$($stat.Project)/_build?view=results&_a=analytics"
        $learnMore = $projectDashboard
        $sharePercent = if ($orgTotalMinutes -gt 0) { [math]::Round((100.0 * $stat.TotalMinutes / $orgTotalMinutes), 2) } else { 0.0 }
        $projectTier = Resolve-ProjectTier -SharePercent $sharePercent
        $baseEvidenceUris = @($projectDashboard, $projectAnalytics) + @($stat.PipelineEvidenceUris)
        $entityRefs = [System.Collections.Generic.List[string]]::new()
        $entityRefs.Add("AdoOrg/$AdoOrg") | Out-Null
        $entityRefs.Add("AdoProject/$AdoOrg/$($stat.Project)") | Out-Null
        foreach ($definitionId in @($stat.DefinitionIds)) {
            if ([string]::IsNullOrWhiteSpace([string]$definitionId)) { continue }
            $entityRefs.Add("AdoPipeline/$AdoOrg/$($stat.Project)/$definitionId") | Out-Null
        }

        if ($sharePercent -ge 40) {
            $ruleId = 'Consumption-MinuteShareHigh'
            $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Source       = 'ado-consumption'
                    RuleId       = $ruleId
                    Category     = 'Cost'
                    Title        = "ADO project '$($stat.Project)' consumes a high share of org runner minutes"
                    Compliant    = $false
                    Severity     = 'Medium'
                    Detail       = "Project consumed $sharePercent% of org runner minutes over the last $DaysBack day(s)."
                    Remediation  = 'Review agent pool usage, split heavy schedules, and optimize long-running jobs.'
                    ResourceId   = $projectId
                    LearnMoreUrl = $learnMore
                    Pillar       = 'Cost Optimization'
                    Impact       = Resolve-Impact -FailRate $stat.FailRate -SharePercent $sharePercent -BudgetPercent 0.0
                    Effort       = 'Low'
                    DeepLinkUrl  = $projectAnalytics
                    EvidenceUris = @($baseEvidenceUris)
                    BaselineTags = @($ruleId, "ProjectTier:$projectTier")
                    EntityRefs   = @($entityRefs)
                    ToolVersion  = $toolVersion
                    SchemaVersion = '1.0'
                })
        }

        if ($stat.FirstAvg -gt 0 -and $stat.SecondAvg -gt ($stat.FirstAvg * 1.25)) {
            $regressionPct = [math]::Round((($stat.SecondAvg - $stat.FirstAvg) / $stat.FirstAvg) * 100.0, 2)
            $ruleId = 'Consumption-DurationRegression'
            $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Source       = 'ado-consumption'
                    RuleId       = $ruleId
                    Category     = 'Cost'
                    Title        = "ADO project '$($stat.Project)' pipeline duration regressed"
                    Compliant    = $false
                    Severity     = 'Medium'
                    Detail       = "Average duration increased $regressionPct% (first half $($stat.FirstAvg) min, second half $($stat.SecondAvg) min)."
                    Remediation  = 'Inspect recent pipeline changes, dependency updates, and queue bottlenecks.'
                    ResourceId   = $projectId
                    LearnMoreUrl = $learnMore
                    Pillar       = 'Cost Optimization'
                    Impact       = Resolve-Impact -FailRate $stat.FailRate -SharePercent $sharePercent -BudgetPercent 0.0
                    Effort       = 'Low'
                    DeepLinkUrl  = $projectAnalytics
                    EvidenceUris = @($baseEvidenceUris)
                    BaselineTags = @($ruleId, "ProjectTier:$projectTier")
                    ScoreDelta   = [double]$regressionPct
                    EntityRefs   = @($entityRefs)
                    ToolVersion  = $toolVersion
                    SchemaVersion = '1.0'
                })
        }

        if ($stat.TotalRuns -gt 0 -and $stat.FailRate -gt 10) {
            $ruleId = 'Consumption-FailRateHigh'
            $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Source       = 'ado-consumption'
                    RuleId       = $ruleId
                    Category     = 'Cost'
                    Title        = "ADO project '$($stat.Project)' failed pipeline rate is high"
                    Compliant    = $false
                    Severity     = 'High'
                    Detail       = "Failed run rate is $($stat.FailRate)% ($($stat.FailedRuns)/$($stat.TotalRuns)) in the last $DaysBack day(s)."
                    Remediation  = 'Fix flaky tests and unstable deployment steps to reduce failed run waste.'
                    ResourceId   = $projectId
                    LearnMoreUrl = $learnMore
                    Pillar       = 'Operational Excellence'
                    Impact       = Resolve-Impact -FailRate $stat.FailRate -SharePercent $sharePercent -BudgetPercent 0.0
                    Effort       = 'Low'
                    DeepLinkUrl  = $projectAnalytics
                    EvidenceUris = @($baseEvidenceUris)
                    BaselineTags = @($ruleId, "ProjectTier:$projectTier")
                    EntityRefs   = @($entityRefs)
                    ToolVersion  = $toolVersion
                    SchemaVersion = '1.0'
                })
        }

        if ($PSBoundParameters.ContainsKey('MonthlyBudgetUsd') -and $MonthlyBudgetUsd -gt 0) {
            $estimatedSpend = [math]::Round(($stat.TotalMinutes * 0.008), 2)
            if ($estimatedSpend -gt $MonthlyBudgetUsd) {
                $budgetVariance = [math]::Round(($estimatedSpend - $MonthlyBudgetUsd), 2)
                $budgetPercent = [math]::Round(($estimatedSpend / $MonthlyBudgetUsd) * 100.0, 2)
                $ruleId = 'Consumption-BudgetOverrun'
                $findings.Add([PSCustomObject]@{
                        Id           = [guid]::NewGuid().ToString()
                        Source       = 'ado-consumption'
                        RuleId       = $ruleId
                        Category     = 'Cost'
                        Title        = "ADO project '$($stat.Project)' estimated pipeline spend exceeded budget"
                        Compliant    = $false
                        Severity     = 'High'
                        Detail       = "Estimated spend $$estimatedSpend exceeded configured budget $$MonthlyBudgetUsd at 0.008 USD per minute."
                        Remediation  = 'Tune trigger volume, queue concurrency, and long-running stages.'
                        ResourceId   = $projectId
                        LearnMoreUrl = $learnMore
                        Pillar       = 'Cost Optimization'
                        Impact       = Resolve-Impact -FailRate $stat.FailRate -SharePercent $sharePercent -BudgetPercent $budgetPercent
                        Effort       = 'Low'
                        DeepLinkUrl  = $projectAnalytics
                        EvidenceUris = @($baseEvidenceUris)
                        BaselineTags = @($ruleId, "ProjectTier:$projectTier")
                        ScoreDelta   = [double]$budgetVariance
                        EntityRefs   = @($entityRefs)
                        ToolVersion  = $toolVersion
                        SchemaVersion = '1.0'
                    })
            }
        }
    }

    return [PSCustomObject]@{
        Source   = 'ado-consumption'
        Status   = 'Success'
        Message  = Remove-Credentials "Scanned $($projectStats.Count) project(s); produced $($findings.Count) ADO consumption finding(s)."
        ToolVersion = $toolVersion
        Findings = @($findings)
    }
} catch {
    $msg = Remove-Credentials ([string]$_.Exception.Message)
    Write-Warning "ADO consumption scan failed: $msg"
    return [PSCustomObject]@{
        Source   = 'ado-consumption'
        Status   = 'Failed'
        Message  = $msg
        Findings = @()
    }    Errors   = @()
$3
}

