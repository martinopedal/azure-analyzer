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
$errorsPath = Join-Path $sharedDir 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
}
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
            $sanitizedOutput = Remove-Credentials -Text ([string]$result.Output)
            $reason = "gh api $Endpoint failed (exit $($result.ExitCode))"
            # Keep transient hints (HTTP 429, rate limit) in Reason so Invoke-WithRetry can classify,
            # but don't embed the full CLI output here - that goes in Details only.
            if ($sanitizedOutput -match '\b(408|429|503|504)\b') {
                $reason += "; HTTP $($Matches[1])"
            } elseif ($sanitizedOutput -match '(?i)(rate limit|throttl|timed out|timeout|service unavailable|temporarily unavailable)') {
                $reason += '; transient response'
            }
            throw (Format-FindingErrorMessage (New-FindingError `
                -Source 'wrapper:gh-actions-billing' `
                -Category 'UnexpectedFailure' `
                -Reason $reason `
                -Remediation 'Verify gh auth status and that the endpoint is correct.' `
                -Details $sanitizedOutput))
        }
        $text = [string]$result.Output
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [PSCustomObject]@{}
        }
        return $text | ConvertFrom-Json -Depth 100
    }
}

function Get-GhToolVersion {
    try {
        $versionResult = Invoke-WithTimeout -Command 'gh' -Arguments @('--version') -TimeoutSec 300
        if ($versionResult.ExitCode -ne 0) { return 'unknown' }
        $versionText = if ($versionResult.Output -is [array]) { ($versionResult.Output -join ' ') } else { [string]$versionResult.Output }
        $match = [regex]::Match($versionText, 'gh version\s+([0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9\.-]+)?)')
        if ($match.Success) { return $match.Groups[1].Value }
        $trimmed = $versionText.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { return $trimmed }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Convert-ToRunnerTag {
    param (
        [object] $Run,
        [string] $Fallback = 'ubuntu'
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    $labels = if ($Run -and $Run.PSObject.Properties['labels']) { @($Run.labels) } else { @() }
    foreach ($label in $labels) { if ($label) { $candidates.Add(([string]$label).ToLowerInvariant()) | Out-Null } }
    foreach ($propertyName in @('name', 'display_title', 'path', 'runner_name', 'runner_group_name')) {
        if ($Run -and $Run.PSObject.Properties[$propertyName] -and $Run.$propertyName) {
            $candidates.Add(([string]$Run.$propertyName).ToLowerInvariant()) | Out-Null
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -match 'macos|mac') { return 'runner:macos' }
        if ($candidate -match 'windows|win') { return 'runner:windows' }
        if ($candidate -match 'ubuntu|linux') { return 'runner:ubuntu' }
    }

    switch -Regex ($Fallback.ToLowerInvariant()) {
        'mac' { return 'runner:macos' }
        'win' { return 'runner:windows' }
        default { return 'runner:ubuntu' }
    }
}

function Get-OrgRunnerTag {
    param ([object]$Billing)

    $breakdown = if ($Billing -and $Billing.PSObject.Properties['minutes_used_breakdown']) { $Billing.minutes_used_breakdown } else { $null }
    if (-not $breakdown -and $Billing -and $Billing.PSObject.Properties['included_minutes_used_breakdown']) {
        $breakdown = $Billing.included_minutes_used_breakdown
    }
    if (-not $breakdown) { return 'runner:ubuntu' }

    $ubuntu = [double]($breakdown.UBUNTU ?? $breakdown.ubuntu ?? 0)
    $windows = [double]($breakdown.WINDOWS ?? $breakdown.windows ?? 0)
    $macos = [double]($breakdown.MACOS ?? $breakdown.macos ?? 0)
    if ($windows -ge $ubuntu -and $windows -ge $macos) { return 'runner:windows' }
    if ($macos -ge $ubuntu -and $macos -ge $windows) { return 'runner:macos' }
    return 'runner:ubuntu'
}

function Resolve-ImpactLevel {
    param (
        [double] $PaidQuotaRatio = 0.0,
        [double] $BudgetOverrunUsd = 0.0,
        [double] $MinuteDelta = 0.0
    )

    if ($PaidQuotaRatio -gt 0.5 -or $BudgetOverrunUsd -gt 500 -or $MinuteDelta -gt 180) { return 'High' }
    if ($PaidQuotaRatio -gt 0.2 -or $BudgetOverrunUsd -gt 100 -or $MinuteDelta -gt 60) { return 'Medium' }
    return 'Low'
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
    }    Errors   = @()
$3
}

try {
    $sinceUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $DaysBack)
    $billing = Invoke-GhApi -Endpoint "orgs/$Org/settings/billing/actions"
    $toolVersion = Get-GhToolVersion

    $repos = @()
    if ($Repo) {
        $repos = @([PSCustomObject]@{ name = $Repo; full_name = "$Org/$Repo"; owner = [PSCustomObject]@{ login = $Org } })
    } else {
        $repoResponse = Invoke-GhApi -Endpoint "orgs/$Org/repos?per_page=100&type=all"
        $repos = @($repoResponse)
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $repoUsage = [System.Collections.Generic.List[PSCustomObject]]::new()
    $billingUrl = "https://github.com/organizations/$Org/billing"

    $includedMinutes = 0.0
    if ($billing.PSObject.Properties['included_minutes']) { $includedMinutes = [double]$billing.included_minutes }
    $includedUsed = 0.0
    if ($billing.PSObject.Properties['included_minutes_used']) { $includedUsed = [double]$billing.included_minutes_used }
    elseif ($billing.PSObject.Properties['total_minutes_used']) { $includedUsed = [double]$billing.total_minutes_used }
    $paidMinutes = 0.0
    if ($billing.PSObject.Properties['total_paid_minutes_used']) { $paidMinutes = [double]$billing.total_paid_minutes_used }
    $paidQuotaRatio = 0.0
    $totalMinutesUsed = [math]::Max(($includedUsed + $paidMinutes), 0.0)
    if ($totalMinutesUsed -gt 0) {
        $paidQuotaRatio = [math]::Round(($paidMinutes / $totalMinutesUsed), 4)
    } elseif ($includedMinutes -gt 0) {
        $paidQuotaRatio = [math]::Round(($paidMinutes / $includedMinutes), 4)
    }
    $orgRunnerTag = Get-OrgRunnerTag -Billing $billing

    if ($includedMinutes -gt 0 -and $includedUsed -gt $includedMinutes) {
        $scoreDelta = [math]::Round(($includedUsed - $includedMinutes), 2)
        $findings.Add([PSCustomObject]@{
                Id           = [guid]::NewGuid().ToString()
                Source       = 'gh-actions-billing'
                RuleId       = 'GHA-PaidMinutesExceeded'
                Category     = 'Cost'
                Title        = "Org '$Org' exceeded included GitHub Actions minutes"
                Compliant    = $false
                Severity     = 'High'
                Detail       = "Included minutes used $includedUsed exceeds included minutes $includedMinutes."
                Remediation  = 'Review high-minute repositories, optimize workflow runtime, and move heavy workloads to self-hosted runners where appropriate.'
                ResourceId   = "github.com/$($Org.ToLowerInvariant())/_org-billing"
                LearnMoreUrl = $billingUrl
                Pillar       = 'Cost Optimization'
                ScoreDelta   = $scoreDelta
                Impact       = Resolve-ImpactLevel -PaidQuotaRatio $paidQuotaRatio -MinuteDelta $scoreDelta
                Effort       = 'Low'
                DeepLinkUrl  = $billingUrl
                EvidenceUris = @($billingUrl)
                BaselineTags = @('GHA-PaidMinutesExceeded', $orgRunnerTag)
                EntityRefs   = @("org:$Org")
                RemediationSnippets = @(
                    @{
                        language = 'yaml'
                        before   = "runs-on: windows-latest`nstrategy:`n  matrix:`n    os: [ubuntu-latest, windows-latest]"
                        after    = "runs-on: ubuntu-latest`nstrategy:`n  matrix:`n    os: [ubuntu-latest]"
                    }
                )
                ToolVersion  = $toolVersion
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
            $workflowPath = if ($run.PSObject.Properties['path'] -and $run.path) { [string]$run.path } else { ".github/workflows/ci.yml" }
            $workflowRef = if ($run.PSObject.Properties['head_branch'] -and $run.head_branch) { [string]$run.head_branch } else { 'HEAD' }
            $workflowUrl = "https://github.com/$ownerName/$repoName/blob/$workflowRef/$workflowPath"
            $runScoreDelta = [math]::Round([math]::Max(($runMinutes - $baseline), 0.0), 2)
            $runnerTag = Convert-ToRunnerTag -Run $run
            $workflowId = if ($run.PSObject.Properties['workflow_id'] -and $run.workflow_id) { [string]$run.workflow_id } else { '' }
            $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Source       = 'gh-actions-billing'
                    RuleId       = 'GHA-RunAnomaly'
                    Category     = 'Cost'
                    Title        = "Workflow run anomaly in $ownerName/$repoName"
                    Compliant    = $false
                    Severity     = 'Low'
                    Detail       = "Run $runId consumed $runMinutes minutes; comparison baseline is $baseline minutes."
                    Remediation  = 'Inspect the workflow run logs and optimize slow jobs, cache misses, and redundant test matrices.'
                    ResourceId   = "github.com/$($ownerName.ToLowerInvariant())/$($repoName.ToLowerInvariant())"
                    LearnMoreUrl = $runUrl
                    Pillar       = 'Cost Optimization'
                    ScoreDelta   = $runScoreDelta
                    Impact       = Resolve-ImpactLevel -PaidQuotaRatio $paidQuotaRatio -MinuteDelta $runScoreDelta
                    Effort       = 'Low'
                    DeepLinkUrl  = $runUrl
                    EvidenceUris = @($billingUrl, $runUrl, $workflowUrl)
                    BaselineTags = @('GHA-RunAnomaly', $runnerTag)
                    EntityRefs   = @("org:$ownerName", "repo:$ownerName/$repoName") + $(if ($workflowId) { @("workflow:$workflowId") } else { @() })
                    RemediationSnippets = @(
                        @{
                            language = 'yaml'
                            before   = "runs-on: windows-latest`nstrategy:`n  matrix:`n    shard: [1,2,3,4,5,6]"
                            after    = "runs-on: ubuntu-latest`nstrategy:`n  matrix:`n    shard: [1,2,3]"
                        }
                    )
                    ToolVersion  = $toolVersion
                    SchemaVersion = '1.0'
                })
        }
    }

    $topConsumers = @($repoUsage | Sort-Object Total -Descending | Select-Object -First 5)
    foreach ($consumer in $topConsumers) {
        if ($consumer.Total -le 0) { continue }
        $repoUsageUrl = "https://github.com/$($consumer.Org)/$($consumer.Repo)/actions"
        $repoShareRatio = if ($totalMinutesUsed -gt 0) { [math]::Round(($consumer.Total / $totalMinutesUsed), 4) } else { 0.0 }
        $findings.Add([PSCustomObject]@{
                Id           = [guid]::NewGuid().ToString()
                Source       = 'gh-actions-billing'
                RuleId       = 'GHA-TopConsumer'
                Category     = 'Cost'
                Title        = "Top GitHub Actions minute consumer: $($consumer.Org)/$($consumer.Repo)"
                Compliant    = $false
                Severity     = 'Medium'
                Detail       = "Repository used $($consumer.Total) runner minutes in the last $DaysBack day(s)."
                Remediation  = 'Review matrix size, unnecessary workflow triggers, and long-running jobs.'
                ResourceId   = "github.com/$($consumer.Org.ToLowerInvariant())/$($consumer.Repo.ToLowerInvariant())"
                LearnMoreUrl = $repoUsageUrl
                Pillar       = 'Cost Optimization'
                ScoreDelta   = [math]::Round([double]$consumer.Total, 2)
                Impact       = Resolve-ImpactLevel -PaidQuotaRatio ([math]::Max($paidQuotaRatio, $repoShareRatio)) -MinuteDelta $consumer.Total
                Effort       = 'Low'
                DeepLinkUrl  = $repoUsageUrl
                EvidenceUris = @($billingUrl, $repoUsageUrl)
                BaselineTags = @('GHA-TopConsumer', 'runner:ubuntu')
                EntityRefs   = @("org:$($consumer.Org)", "repo:$($consumer.Org)/$($consumer.Repo)")
                RemediationSnippets = @(
                    @{
                        language = 'yaml'
                        before   = "runs-on: ubuntu-latest`non:`n  schedule:`n    - cron: '*/5 * * * *'"
                        after    = "runs-on: ubuntu-latest`non:`n  schedule:`n    - cron: '0 */2 * * *'"
                    }
                )
                ToolVersion  = $toolVersion
                SchemaVersion = '1.0'
            })
    }

    if ($PSBoundParameters.ContainsKey('MonthlyBudgetUsd') -and $MonthlyBudgetUsd -gt 0) {
        $estimatedSpend = [math]::Round(($paidMinutes * 0.008), 2)
        if ($estimatedSpend -gt $MonthlyBudgetUsd) {
            $scoreDelta = [math]::Round(($estimatedSpend - $MonthlyBudgetUsd), 2)
            $findings.Add([PSCustomObject]@{
                    Id           = [guid]::NewGuid().ToString()
                    Source       = 'gh-actions-billing'
                    RuleId       = 'GHA-BudgetOverage'
                    Category     = 'Cost'
                    Title        = "Org '$Org' estimated Actions spend exceeded monthly budget"
                    Compliant    = $false
                    Severity     = 'High'
                    Detail       = "Estimated spend $$estimatedSpend exceeded configured budget $$MonthlyBudgetUsd based on paid minutes ($paidMinutes) at 0.008 USD per minute."
                    Remediation  = 'Set stricter workflow concurrency limits, reduce paid runner use, and enforce workflow ownership review.'
                    ResourceId   = "github.com/$($Org.ToLowerInvariant())/_org-billing"
                    LearnMoreUrl = $billingUrl
                    Pillar       = 'Cost Optimization'
                    ScoreDelta   = $scoreDelta
                    Impact       = Resolve-ImpactLevel -PaidQuotaRatio $paidQuotaRatio -BudgetOverrunUsd $scoreDelta
                    Effort       = 'Low'
                    DeepLinkUrl  = $billingUrl
                    EvidenceUris = @($billingUrl)
                    BaselineTags = @('GHA-BudgetOverage', $orgRunnerTag)
                    EntityRefs   = @("org:$Org")
                    RemediationSnippets = @(
                        @{
                            language = 'yaml'
                            before   = "strategy:`n  matrix:`n    node: [18,20,22]"
                            after    = "strategy:`n  matrix:`n    node: [20]"
                        }
                    )
                    ToolVersion  = $toolVersion
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
    }    Errors   = @()
$3
}
