#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Azure Load Testing failed and regressed test runs.

.DESCRIPTION
    Enumerates Microsoft.LoadTestService/loadTests resources in a subscription,
    lists tests and recent test runs, and emits v1 findings for:
      - Failed or cancelled runs (High)
      - Regressions beyond threshold (Medium)
      - Missing recent runs (Info)
      - Healthy runs (Info, optional via -IncludeHealthyRuns)

    All REST calls are wrapped in Invoke-WithRetry. Optional disk output is
    scrubbed through Remove-Credentials before being written.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $ResourceGroup,
    [string] $LoadTestResourceName,
    [ValidateRange(1, 365)] [int] $DaysBack = 30,
    [ValidateRange(1, 100)] [int] $RegressionThresholdPercent = 10,
    [switch] $IncludeHealthyRuns,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
}

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'loadtesting'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    return [PSCustomObject]$result
}

try {
    Import-Module Az.Accounts -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
} catch {
    Write-Verbose "Import-Module Az.Accounts failed, continuing with existing session context."
}
try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No Az context' }
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [PSCustomObject]$result
}

function Invoke-LoadTestingGetPaged {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Uri,
        [int] $MaxPages = 50
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $pages = 0
    while ($next -and $pages -lt $MaxPages) {
        $pages++
        $resp = Invoke-WithRetry -MaxAttempts 4 -ScriptBlock {
            Invoke-AzRestMethod -Method GET -Uri $next -ErrorAction Stop
        }
        if (-not $resp -or $resp.StatusCode -ge 400) {
            throw "Load Testing REST call failed (HTTP $($resp.StatusCode)): $($resp.Content)"
        }

        $payload = $resp.Content | ConvertFrom-Json -Depth 30
        if ($payload.PSObject.Properties['value'] -and $payload.value) {
            foreach ($v in @($payload.value)) {
                $items.Add($v) | Out-Null
            }
        }
        $next = $null
        if ($payload.PSObject.Properties['nextLink'] -and $payload.nextLink) {
            $next = [string]$payload.nextLink
        }
    }

    return @($items)
}

function Get-PortalRunUrl {
    param(
        [Parameter(Mandatory)] [string] $ResourceId,
        [Parameter(Mandatory)] [string] $RunId
    )
    $encoded = [System.Uri]::EscapeDataString($ResourceId)
    return "https://portal.azure.com/#view/Microsoft_Azure_LoadTesting/LoadTestResourceMenuBlade/~/testRun/resourceId/$encoded/testRunId/$RunId"
}

function Get-PortalResourceUrl {
    param([Parameter(Mandatory)] [string] $ResourceId)
    return "https://portal.azure.com/#@/resource$ResourceId/overview"
}

function Get-OptionalString {
    param([object] $Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Get-RunTimestampUtc {
    param([object] $Run)
    foreach ($candidate in @(
            (Get-PropertyPathValue -Object $Run -Path 'properties.endDateTime'),
            (Get-PropertyPathValue -Object $Run -Path 'properties.startDateTime'),
            (Get-PropertyPathValue -Object $Run -Path 'properties.lastModifiedDateTime'),
            (Get-PropertyPathValue -Object $Run -Path 'properties.createdDateTime'),
            (Get-PropertyPathValue -Object $Run -Path 'endDateTime'),
            (Get-PropertyPathValue -Object $Run -Path 'startDateTime'),
            (Get-PropertyPathValue -Object $Run -Path 'createdDateTime')
        )) {
        if ($null -eq $candidate) { continue }
        try {
            return ([datetime]$candidate).ToUniversalTime()
        } catch {
            continue
        }
    }
    return $null
}

function Get-PropertyPathValue {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Path
    )
    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

function Get-RunMetric {
    param(
        [Parameter(Mandatory)] [object] $Run,
        [Parameter(Mandatory)] [string[]] $CandidatePaths,
        [string[]] $ArrayMetricNames
    )

    foreach ($path in $CandidatePaths) {
        $value = Get-PropertyPathValue -Object $Run -Path $path
        if ($null -eq $value) { continue }
        try {
            return [double]$value
        } catch {
            continue
        }
    }

    $metricArrays = @(
        (Get-PropertyPathValue -Object $Run -Path 'properties.metrics'),
        (Get-PropertyPathValue -Object $Run -Path 'properties.testRunStatistics.metrics'),
        (Get-PropertyPathValue -Object $Run -Path 'metrics')
    )
    foreach ($arr in $metricArrays) {
        if (-not $arr) { continue }
        foreach ($entry in @($arr)) {
            $name = Get-OptionalString $entry.name
            if (-not $name) { $name = Get-OptionalString $entry.metricName }
            if (-not $name) { continue }
            if ($ArrayMetricNames -and ($ArrayMetricNames -notcontains $name.ToLowerInvariant())) { continue }
            foreach ($field in @('value', 'metricValue', 'average', 'max', 'p95')) {
                if ($entry.PSObject.Properties[$field] -and $null -ne $entry.$field) {
                    try { return [double]$entry.$field } catch { }
                }
            }
        }
    }

    return $null
}

function Test-PassFailCriteriaFailed {
    param([object] $Run)

    $criteria = Get-PropertyPathValue -Object $Run -Path 'properties.passFailCriteria'
    if (-not $criteria) { return $false }

    foreach ($collectionName in @('passFailMetrics', 'passFailAggregation', 'metrics')) {
        if (-not $criteria.PSObject.Properties[$collectionName]) { continue }
        foreach ($metric in @($criteria.$collectionName)) {
            foreach ($field in @('status', 'result', 'state')) {
                if ($metric.PSObject.Properties[$field] -and $metric.$field) {
                    if ([string]$metric.$field -match '^(?i)failed$') { return $true }
                }
            }
        }
    }

    return $false
}

$findings = [System.Collections.Generic.List[object]]::new()
$apiVersion = '2022-12-01'
$windowStartUtc = (Get-Date).ToUniversalTime().AddDays(-$DaysBack)

function Add-LoadTestingFinding {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Severity,
        [Parameter(Mandatory)] [bool] $Compliant,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Detail,
        [Parameter(Mandatory)] [string] $ResourceId,
        [Parameter(Mandatory)] [string] $LearnMoreUrl,
        [string] $Remediation = '',
        [hashtable] $Extras
    )

    $row = [ordered]@{
        Id           = $Id
        Source       = 'loadtesting'
        Category     = 'Performance'
        Severity     = $Severity
        Compliant    = $Compliant
        Title        = $Title
        Detail       = $Detail
        Remediation  = $Remediation
        ResourceId   = $ResourceId
        LearnMoreUrl = $LearnMoreUrl
    }
    if ($Extras) {
        foreach ($k in $Extras.Keys) {
            $row[$k] = $Extras[$k]
        }
    }
    $findings.Add([PSCustomObject]$row) | Out-Null
}

try {
    $resourceUris = @()
    if ($ResourceGroup -and $LoadTestResourceName) {
        $resourceUris += "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$([System.Uri]::EscapeDataString($ResourceGroup))/providers/Microsoft.LoadTestService/loadTests/$([System.Uri]::EscapeDataString($LoadTestResourceName))?api-version=$apiVersion"
    } elseif ($ResourceGroup) {
        $resourceUris += "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$([System.Uri]::EscapeDataString($ResourceGroup))/providers/Microsoft.LoadTestService/loadTests?api-version=$apiVersion"
    } else {
        $resourceUris += "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.LoadTestService/loadTests?api-version=$apiVersion"
    }

    $loadTestResources = [System.Collections.Generic.List[object]]::new()
    foreach ($resourceUri in $resourceUris) {
        $items = Invoke-LoadTestingGetPaged -Uri $resourceUri
        foreach ($item in @($items)) {
            $loadTestResources.Add($item) | Out-Null
        }
    }

    if ($LoadTestResourceName -and -not $ResourceGroup) {
        $filtered = @($loadTestResources | Where-Object { ([string]$_.name) -ieq $LoadTestResourceName })
        $loadTestResources = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $filtered) { $loadTestResources.Add($item) | Out-Null }
    }

    if ($loadTestResources.Count -eq 0) {
        $result.Status = 'Skipped'
        $result.Message = 'No Azure Load Testing resources found in the requested scope.'
        return [PSCustomObject]$result
    }

    foreach ($resource in $loadTestResources) {
        $resourceId = [string]$resource.id
        $resourceName = [string]$resource.name
        if (-not $resourceId) { continue }

        $testsUri = "https://management.azure.com$resourceId/tests?api-version=$apiVersion"
        $tests = @()
        try {
            $tests = @(Invoke-LoadTestingGetPaged -Uri $testsUri)
        } catch {
            Write-Warning ("Load testing tests query failed for {0}: {1}" -f $resourceName, (Remove-Credentials -Text ([string]$_.Exception.Message)))
            continue
        }

        foreach ($test in $tests) {
            $testName = [string]$test.name
            if (-not $testName) { continue }

            $testNameEncoded = [System.Uri]::EscapeDataString($testName)
            $runsUri = "https://management.azure.com$resourceId/tests/$testNameEncoded/test-runs?api-version=$apiVersion"
            $runs = @()
            try {
                $runs = @(Invoke-LoadTestingGetPaged -Uri $runsUri)
            } catch {
                Write-Warning ("Load testing runs query failed for {0}/{1}: {2}" -f $resourceName, $testName, (Remove-Credentials -Text ([string]$_.Exception.Message)))
                continue
            }

            $runsInWindow = @($runs | Where-Object {
                    $ts = Get-RunTimestampUtc -Run $_
                    $null -ne $ts -and $ts -ge $windowStartUtc
                } | Sort-Object -Property @{ Expression = { Get-RunTimestampUtc -Run $_ } } -Descending)

            if ($runsInWindow.Count -eq 0) {
                Add-LoadTestingFinding -Id "loadtesting/$resourceName/$testName/no-runs" `
                    -Severity 'Info' -Compliant $false `
                    -Title "Load test '$testName' has no runs in the last $DaysBack day(s)" `
                    -Detail "No test runs were found for load test '$testName' in resource '$resourceName' during the configured lookback window." `
                    -ResourceId $resourceId `
                    -LearnMoreUrl (Get-PortalResourceUrl -ResourceId $resourceId) `
                    -Remediation 'Run a baseline test and keep recurring runs to detect reliability and performance regressions.' `
                    -Extras @{
                        LoadTestResourceName = $resourceName
                        TestName             = $testName
                        DaysBack             = $DaysBack
                    }
                continue
            }

            $latest = $runsInWindow[0]
            $previous = if ($runsInWindow.Count -gt 1) { $runsInWindow[1] } else { $null }

            $runId = Get-OptionalString $latest.name
            if (-not $runId) { $runId = Get-OptionalString $latest.id }
            if (-not $runId) { $runId = ([guid]::NewGuid().ToString()) }

            $runStatusRaw = Get-OptionalString (Get-PropertyPathValue -Object $latest -Path 'properties.status')
            if (-not $runStatusRaw) { $runStatusRaw = Get-OptionalString (Get-PropertyPathValue -Object $latest -Path 'status') }
            $runStatus = $runStatusRaw.ToUpperInvariant()

            $failureCause = Get-OptionalString (Get-PropertyPathValue -Object $latest -Path 'properties.errorDetails.message')
            if (-not $failureCause) { $failureCause = Get-OptionalString (Get-PropertyPathValue -Object $latest -Path 'properties.failureReason') }
            if (-not $failureCause) { $failureCause = Get-OptionalString (Get-PropertyPathValue -Object $latest -Path 'properties.message') }
            if (-not $failureCause) { $failureCause = 'No failure cause provided by the API.' }

            $criteriaFailed = Test-PassFailCriteriaFailed -Run $latest
            $isFailed = $runStatus -in @('FAILED', 'CANCELLED') -or $criteriaFailed
            $hadRegression = $false

            if ($isFailed) {
                Add-LoadTestingFinding -Id "loadtesting/$resourceName/$testName/$runId/failed" `
                    -Severity 'High' -Compliant $false `
                    -Title "Load test '$testName' run $runId failed: $failureCause" `
                    -Detail "Latest run status is '$runStatus'. Pass/fail criteria failed: $criteriaFailed. Cause: $failureCause" `
                    -ResourceId $resourceId `
                    -LearnMoreUrl (Get-PortalRunUrl -ResourceId $resourceId -RunId $runId) `
                    -Remediation 'Review test logs, recent deployment changes, and backend telemetry before promoting the release.' `
                    -Extras @{
                        LoadTestResourceName = $resourceName
                        TestName             = $testName
                        TestRunId            = $runId
                        RunStatus            = $runStatus
                        FailureCause         = $failureCause
                        PassFailCriteriaFailed = $criteriaFailed
                    }
            }

            if ($previous) {
                $metricDefinitions = @(
                    @{
                        Name           = 'ResponseTimeP95'
                        Display        = 'response time p95'
                        HigherIsWorse  = $true
                        Paths          = @(
                            'properties.testRunStatistics.responseTimeP95',
                            'properties.statistics.responseTimeP95',
                            'properties.responseTimeMetrics.p95',
                            'properties.responseTimeP95'
                        )
                        MetricNames    = @('responsetimep95', 'p95', 'latencyp95')
                    },
                    @{
                        Name           = 'ErrorRate'
                        Display        = 'error rate'
                        HigherIsWorse  = $true
                        Paths          = @(
                            'properties.testRunStatistics.errorRate',
                            'properties.statistics.errorRate',
                            'properties.errorRate'
                        )
                        MetricNames    = @('errorrate', 'errorpercentage', 'errorspercentage')
                    },
                    @{
                        Name           = 'RequestsPerSecond'
                        Display        = 'requests per second'
                        HigherIsWorse  = $false
                        Paths          = @(
                            'properties.testRunStatistics.requestsPerSecond',
                            'properties.statistics.requestsPerSecond',
                            'properties.rps'
                        )
                        MetricNames    = @('requestspersecond', 'rps', 'throughput')
                    }
                )

                foreach ($metric in $metricDefinitions) {
                    $latestValue = Get-RunMetric -Run $latest -CandidatePaths $metric.Paths -ArrayMetricNames $metric.MetricNames
                    $previousValue = Get-RunMetric -Run $previous -CandidatePaths $metric.Paths -ArrayMetricNames $metric.MetricNames
                    if ($null -eq $latestValue -or $null -eq $previousValue) { continue }
                    if ($previousValue -eq 0) { continue }

                    $deltaPercent = if ($metric.HigherIsWorse) {
                        (($latestValue - $previousValue) / [math]::Abs($previousValue)) * 100
                    } else {
                        (($previousValue - $latestValue) / [math]::Abs($previousValue)) * 100
                    }

                    if ($deltaPercent -ge $RegressionThresholdPercent) {
                        $hadRegression = $true
                        $roundedDelta = [math]::Round($deltaPercent, 2)
                        Add-LoadTestingFinding -Id "loadtesting/$resourceName/$testName/$runId/regression/$($metric.Name)" `
                            -Severity 'Medium' -Compliant $false `
                            -Title "Load test '$testName' regressed by $roundedDelta% in $($metric.Display)" `
                            -Detail "Latest value: $([math]::Round($latestValue, 4)); baseline value: $([math]::Round($previousValue, 4)); threshold: $RegressionThresholdPercent%." `
                            -ResourceId $resourceId `
                            -LearnMoreUrl (Get-PortalRunUrl -ResourceId $resourceId -RunId $runId) `
                            -Remediation 'Investigate recent code and infrastructure changes, then re-run load tests before release.' `
                            -Extras @{
                                LoadTestResourceName  = $resourceName
                                TestName              = $testName
                                TestRunId             = $runId
                                MetricName            = $metric.Name
                                MetricDisplayName     = $metric.Display
                                BaselineValue         = [math]::Round($previousValue, 6)
                                CurrentValue          = [math]::Round($latestValue, 6)
                                RegressionPercent     = $roundedDelta
                                ThresholdPercent      = $RegressionThresholdPercent
                            }
                    }
                }
            }

            if ($IncludeHealthyRuns -and (-not $isFailed) -and (-not $hadRegression)) {
                Add-LoadTestingFinding -Id "loadtesting/$resourceName/$testName/$runId/healthy" `
                    -Severity 'Info' -Compliant $true `
                    -Title "Load test '$testName' run $runId is healthy" `
                    -Detail "Latest run status is '$runStatus' and no tracked metric regressed beyond $RegressionThresholdPercent% against the prior run." `
                    -ResourceId $resourceId `
                    -LearnMoreUrl (Get-PortalRunUrl -ResourceId $resourceId -RunId $runId) `
                    -Remediation '' `
                    -Extras @{
                        LoadTestResourceName = $resourceName
                        TestName             = $testName
                        TestRunId            = $runId
                        RunStatus            = $runStatus
                        ThresholdPercent     = $RegressionThresholdPercent
                    }
            }
        }
    }
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Azure Load Testing query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [PSCustomObject]$result
}

$result.Findings = @($findings)
$result.Message = "Scanned Azure Load Testing resources for the last $DaysBack day(s); emitted $($findings.Count) finding(s). Regression threshold: $RegressionThresholdPercent%."

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $raw = Join-Path $OutputPath "loadtesting-$SubscriptionId-$(Get-Date -Format yyyyMMddHHmmss).json"
        Set-Content -Path $raw -Value (Remove-Credentials ($result | ConvertTo-Json -Depth 30)) -Encoding utf8
    } catch {
        Write-Warning "Failed to write raw load testing JSON: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [PSCustomObject]$result
