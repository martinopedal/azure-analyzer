#Requires -Version 7.4
<#
.SYNOPSIS
    GitHub Actions billing and runtime cost telemetry.
.DESCRIPTION
    Uses gh api to collect org billing signals plus per-repo workflow run
    durations. Emits v1 findings for:
      - org included minute overage
      - top repository consumers (top 5 by minutes)
      - long-run anomaly (>60 min and above 30-day average)
.PARAMETER Org
    GitHub organization name.
.PARAMETER Repo
    Optional repo filter. When omitted, all org repos are queried.
.PARAMETER DaysBack
    Lookback window for workflow runs. Defaults to 30.
.PARAMETER MonthlyBudgetUsd
    Optional soft budget threshold for estimated paid minute cost.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Org,

    [string] $Repo,

    [ValidateRange(1, 365)]
    [int] $DaysBack = 30,

    [double] $MonthlyBudgetUsd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = Join-Path $PSScriptRoot 'shared'
. (Join-Path $sharedDir 'Retry.ps1')
. (Join-Path $sharedDir 'Sanitize.ps1')
$installerPath = Join-Path $sharedDir 'Installer.ps1'
if (Test-Path $installerPath) { . $installerPath }
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param([string]$Command, [string[]]$Arguments, [int]$TimeoutSec = 300)
        $stdout = & $Command @Arguments 2>&1 | Out-String
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $stdout }
    }
}

function Invoke-GhApi {
    param (
        [Parameter(Mandatory)]
        [string] $Endpoint
    )

    Invoke-WithRetry -ScriptBlock {
        $result = Invoke-WithTimeout -Command 'gh' -Arguments @('api', $Endpoint) -TimeoutSec 300
        if ($result.ExitCode -ne 0) {
            throw "gh api $Endpoint failed: $($result.Output)"
        }
        $text = [string]$result.Output
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [PSCustomObject]@{}
        }
        return $text | ConvertFrom-Json -Depth 100
    }
}

function Get-RepoRunMinutes {
    param (
        [Parameter(Mandatory)]
        [string] $OrgName,
        [Parameter(Mandatory)]
        [string] $RepoName,
        [Parameter(Mandatory)]
        [datetime] $SinceUtc
    )

    $sinceDate = $SinceUtc.ToString('yyyy-MM-dd')
    $createdFilter = [uri]::EscapeDataString(">=$sinceDate")
    $runsResponse = Invoke-GhApi -Endpoint "repos/$OrgName/$RepoName/actions/runs?per_page=100&created=$createdFilter"
    $runs = if ($runsResponse -and $runsResponse.PSObject.Properties['workflow_runs']) { @($runsResponse.workflow_runs) } else { @() }

    $durations = [System.Collections.Generic.List[double]]::new()
    foreach ($run in $runs) {
        $minutes = 0.0
        if ($run.PSObject.Properties['run_duration_ms'] -and $run.run_duration_ms) {
            $minutes = [math]::Round(([double]$run.run_duration_ms / 60000.0), 2)
        } elseif ($run.PSObject.Properties['run_started_at'] -and $run.PSObject.Properties['updated_at'] -and $run.run_started_at -and $run.updated_at) {
            try {
                $start = [datetime]$run.run_started_at
                $finish = [datetime]$run.updated_at
                if ($finish -gt $start) {
                    $minutes = [math]::Round(($finish - $start).TotalMinutes, 2)
                }
            } catch {
                $minutes = 0.0
            }
        }
        if ($minutes -gt 0) {
            $durations.Add($minutes)
        }
    }

    $total = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Sum).Sum, 2) } else { 0.0 }
    $avg = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Average).Average, 2) } else { 0.0 }
    return [PSCustomObject]@{
        Runs      = $runs
        Durations = @($durations)
        Total     = $total
        Average   = $avg
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    return [PSCustomObject]@{
        Source   = 'gh-actions-billing'
        Status   = 'Skipped'
        Message  = 'gh CLI not installed. Install GitHub CLI and authenticate with gh auth login.'
        Findings = @()
    }
}

try {
    $sinceUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $DaysBack)
    $billing = Invoke-GhApi -Endpoint "orgs/$Org/settings/billing/actions"

    $repos = @()
    if ($Repo) {
        $repos = @([PSCustomObject]@{ name = $Repo; full_name = "$Org/$Repo"; owner = [PSCustomObject]@{ login = $Org } })
    } else {
        $repoResponse = Invoke-GhApi -Endpoint "orgs/$Org/repos?per_page=100&type=all"
        $repos = @($repoResponse)
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $repoUsage = [System.Collections.Generic.List[PSCustomObject]]::new()
    $billingUrl = "https://github.com/organizations/$Org/settings/billing/actions"

    $includedMinutes = 0.0
    if ($billing.PSObject.Properties['included_minutes']) { $includedMinutes = [double]$billing.included_minutes }
    $includedUsed = 0.0
    if ($billing.PSObject.Properties['included_minutes_used']) { $includedUsed = [double]$billing.included_minutes_used }
    elseif ($billing.PSObject.Properties['total_minutes_used']) { $includedUsed = [double]$billing.total_minutes_used }
    $paidMinutes = 0.0
    if ($billing.PSObject.Properties['total_paid_minutes_used']) { $paidMinutes = [double]$billing.total_paid_minutes_used }

    if ($includedMinutes -gt 0 -and $includedUsed -gt $includedMinutes) {
        $findings.Add([PSCustomObject]@{
                Id           = [guid]::NewGuid().ToString()
                Source       = 'gh-actions-billing'
                RuleId       = 'gh-actions.org-over-budget'
                Category     = 'Cost'
                Title        = "Org '$Org' exceeded included GitHub Actions minutes"
                Compliant    = $false
                Severity     = 'High'
                Detail       = "Included minutes used $includedUsed exceeds included minutes $includedMinutes."
                Remediation  = 'Review high-minute repositories, optimize workflow runtime, and move heavy workloads to self-hosted runners where appropriate.'
                ResourceId   = "github.com/$($Org.ToLowerInvariant())/_org-billing"
                LearnMoreUrl = $billingUrl
                SchemaVersion = '1.0'
            })
    }

    foreach ($repoItem in $repos) {
        if (-not $repoItem) { continue }
        $repoName = if ($repoItem.PSObject.Properties['name'] -and $repoItem.name) { [string]$repoItem.name } else { '' }
        if (-not $repoName) { continue }
        $ownerName = if ($repoItem.PSObject.Properties['owner'] -and $repoItem.owner -and $repoItem.owner.PSObject.Properties['login']) { [string]$repoItem.owner.login } else { $Org }
        $usage = Get-RepoRunMinutes -OrgName $ownerName -RepoName $repoName -SinceUtc $sinceUtc
        $repoUsage.Add([PSCustomObject]@{
                Org      = $ownerName
                Repo     = $repoName
                Total    = $usage.Total
                Average  = $usage.Average
                Runs     = $usage.Runs
            })

        foreach ($run in @($usage.Runs)) {
            $runMinutes = 0.0
            if ($run.PSObject.Properties['run_duration_ms'] -and $run.run_duration_ms) {
                $runMinutes = [math]::Round(([double]$run.run_duration_ms / 60000.0), 2)
            } elseif ($run.PSObject.Properties['run_started_at'] -and $run.PSObject.Properties['updated_at'] -and $run.run_started_at -and $run.updated_at) {
                try {
                    $start = [datetime]$run.run_started_at
                    $finish = [datetime]$run.updated_at
                    if ($finish -gt $start) { $runMinutes = [math]::Round(($finish - $start).TotalMinutes, 2) }
                } catch {
                    $runMinutes = 0.0
                }
            }
            if ($runMinutes -le 60) { continue }

            $baseline = $usage.Average
            if ($usage.Durations.Count -gt 1) {
                $other = @($usage.Durations | Where-Object { $_ -ne $runMinutes } | Select-Object -First ($usage.Durations.Count - 1))
                if (@($other).Count -gt 0) {
                    $baseline = [math]::Round((@($other) | Measure-Object -Average).Average, 2)
                }
            }
            if ($baseline -gt 0 -and $runMinutes -le ($baseline * 2.0)) { continue }

            $runId = if ($run.PSObject.Properties['id']) { [string]$run.id } else { 'unknown' }
            $runUrl = if ($run.PSObject.Properties['html_url'] -and $run.html_url) { [string]$run.html_url } else { "https://github.com/$ownerName/$repoName/actions" }
            $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Source       = 'gh-actions-billing'
                    RuleId       = 'gh-actions.run-duration-anomaly'
                    Category     = 'Cost'
                    Title        = "Workflow run anomaly in $ownerName/$repoName"
                    Compliant    = $false
                    Severity     = 'Low'
                    Detail       = "Run $runId consumed $runMinutes minutes; comparison baseline is $baseline minutes."
                    Remediation  = 'Inspect the workflow run logs and optimize slow jobs, cache misses, and redundant test matrices.'
                    ResourceId   = "github.com/$($ownerName.ToLowerInvariant())/$($repoName.ToLowerInvariant())"
                    LearnMoreUrl = $runUrl
                    SchemaVersion = '1.0'
                })
        }
    }

    $topConsumers = @($repoUsage | Sort-Object Total -Descending | Select-Object -First 5)
    foreach ($consumer in $topConsumers) {
        if ($consumer.Total -le 0) { continue }
        $findings.Add([PSCustomObject]@{
                Id           = [guid]::NewGuid().ToString()
                Source       = 'gh-actions-billing'
                RuleId       = 'gh-actions.top-consumer'
                Category     = 'Cost'
                Title        = "Top GitHub Actions minute consumer: $($consumer.Org)/$($consumer.Repo)"
                Compliant    = $false
                Severity     = 'Medium'
                Detail       = "Repository used $($consumer.Total) runner minutes in the last $DaysBack day(s)."
                Remediation  = 'Review matrix size, unnecessary workflow triggers, and long-running jobs.'
                ResourceId   = "github.com/$($consumer.Org.ToLowerInvariant())/$($consumer.Repo.ToLowerInvariant())"
                LearnMoreUrl = "https://github.com/$($consumer.Org)/$($consumer.Repo)/actions"
                SchemaVersion = '1.0'
            })
    }

    if ($PSBoundParameters.ContainsKey('MonthlyBudgetUsd') -and $MonthlyBudgetUsd -gt 0) {
        $estimatedSpend = [math]::Round(($paidMinutes * 0.008), 2)
        if ($estimatedSpend -gt $MonthlyBudgetUsd) {
            $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Source       = 'gh-actions-billing'
                    RuleId       = 'gh-actions.monthly-budget-exceeded'
                    Category     = 'Cost'
                    Title        = "Org '$Org' estimated Actions spend exceeded monthly budget"
                    Compliant    = $false
                    Severity     = 'High'
                    Detail       = "Estimated spend $$estimatedSpend exceeded configured budget $$MonthlyBudgetUsd based on paid minutes ($paidMinutes) at 0.008 USD per minute."
                    Remediation  = 'Set stricter workflow concurrency limits, reduce paid runner use, and enforce workflow ownership review.'
                    ResourceId   = "github.com/$($Org.ToLowerInvariant())/_org-billing"
                    LearnMoreUrl = $billingUrl
                    SchemaVersion = '1.0'
                })
        }
    }

    return [PSCustomObject]@{
        Source   = 'gh-actions-billing'
        Status   = 'Success'
        Message  = Remove-Credentials "Scanned $($repos.Count) repo(s); produced $($findings.Count) GitHub Actions cost finding(s)."
        Findings = @($findings)
    }
} catch {
    $msg = Remove-Credentials ([string]$_.Exception.Message)
    Write-Warning "GitHub Actions billing scan failed: $msg"
    return [PSCustomObject]@{
        Source   = 'gh-actions-billing'
        Status   = 'Failed'
        Message  = $msg
        Findings = @()
    }
}
