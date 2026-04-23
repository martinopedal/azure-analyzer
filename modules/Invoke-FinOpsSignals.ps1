#requires -Version 7.0
<#
.SYNOPSIS
    FinOps signals wrapper - detect likely idle or unused Azure resources.

.DESCRIPTION
    Correlates Azure Resource Graph signals from queries/finops/finops-*.json with monthly
    resource-level cost data from the Cost Management query API. Emits a standard v1
    wrapper envelope consumed by Normalize-FinOpsSignals.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string[]] $QueryFiles,
    [string] $OutputPath,
    [ValidateRange(1, 3650)]
    [int] $SnapshotAgeThresholdDays = 90
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

$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
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

function Invoke-SearchAzGraphAllResults {
    param (
        [Parameter(Mandatory)]
        [string] $Query,
        [Parameter(Mandatory)]
        [string] $SubscriptionId,
        [int] $PageSize = 1000
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $pageResult = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
            $params = @{
                Query        = $Query
                Subscription = $SubscriptionId
                First        = $PageSize
                ErrorAction  = 'Stop'
            }
            if ($skipToken) { $params['SkipToken'] = $skipToken }
            Search-AzGraph @params
        }

        $pageRows = @()
        $nextToken = $null
        if ($pageResult -and $pageResult.PSObject.Properties['Data']) {
            $pageRows = @($pageResult.Data)
            if ($pageResult.PSObject.Properties['SkipToken']) {
                $nextToken = [string]$pageResult.SkipToken
            }
        } else {
            $pageRows = @($pageResult)
        }

        foreach ($row in $pageRows) {
            if ($row) { $rows.Add($row) | Out-Null }
        }
        $skipToken = if ([string]::IsNullOrWhiteSpace($nextToken)) { $null } else { $nextToken }
    } while ($skipToken)

    return @($rows)
}

function Get-CostMap {
    param ([string] $SubscriptionId)

    $costMap = @{}
    $currency = ''
    $toDate = (Get-Date).ToUniversalTime().Date
    $fromDate = $toDate.AddDays(-30)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
    $payloadObj = @{
        type = 'Usage'
        timeframe = 'Custom'
        timePeriod = @{
            from = $fromDate.ToString('yyyy-MM-dd')
            to   = $toDate.ToString('yyyy-MM-dd')
        }
        dataset = @{
            granularity = 'None'
            aggregation = @{
                totalCost = @{
                    name     = 'PreTaxCost'
                    function = 'Sum'
                }
            }
            grouping = @(
                @{
                    type = 'Dimension'
                    name = 'ResourceId'
                }
            )
        }
    }
    $payload = $payloadObj | ConvertTo-Json -Depth 10 -Compress

    $resp = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
        Invoke-AzRestMethod -Method POST -Uri $uri -Payload $payload -ErrorAction Stop
    }

    if (-not $resp -or $resp.StatusCode -ge 400) {
        $statusCode = if ($resp) { $resp.StatusCode } else { 'null' }
        throw (Format-FindingErrorMessage (New-FindingError `
            -Source 'wrapper:finops-signals' `
            -Category 'TransientFailure' `
            -Reason "Cost Management query failed with status ${statusCode}." `
            -Remediation 'Retry; ensure Cost Management Reader role on the scope.'))
    }

    $body = $resp.Content | ConvertFrom-Json -Depth 20
    if ($body.properties.PSObject.Properties['currency'] -and $body.properties.currency) {
        $currency = [string]$body.properties.currency
    }
    $columns = @($body.properties.columns)
    $rowsRaw = @($body.properties.rows)
    if ($rowsRaw.Count -eq 0) {
        return [PSCustomObject]@{ CostMap = $costMap; Currency = $currency }
    }

    $columnNames = @($columns | ForEach-Object { [string]$_.name })
    $resourceIdIndex = [array]::IndexOf($columnNames, 'ResourceId')
    if ($resourceIdIndex -lt 0) { $resourceIdIndex = [array]::IndexOf($columnNames, 'ResourceId1') }
    $costIndex = [array]::IndexOf($columnNames, 'PreTaxCost')
    if ($costIndex -lt 0) { $costIndex = [array]::IndexOf($columnNames, 'Cost') }
    if ($resourceIdIndex -lt 0 -or $costIndex -lt 0) {
        throw (Format-FindingErrorMessage (New-FindingError `
            -Source 'wrapper:finops-signals' `
            -Category 'UnexpectedFailure' `
            -Reason 'Cost Management response missing expected ResourceId/Cost columns.' `
            -Remediation 'Inspect the Cost Management query schema; the API response shape may have changed.'))
    }

    $rows = @()
    if ($rowsRaw.Count -gt 0 -and ($rowsRaw[0] -is [string] -or $rowsRaw[0] -isnot [System.Collections.IEnumerable])) {
        if ($columnNames.Count -gt 0 -and ($rowsRaw.Count % $columnNames.Count) -eq 0) {
            for ($i = 0; $i -lt $rowsRaw.Count; $i += $columnNames.Count) {
                $rows += ,@($rowsRaw[$i..([math]::Min($i + $columnNames.Count - 1, $rowsRaw.Count - 1))])
            }
        } else {
            $rows += ,@($rowsRaw)
        }
    } else {
        $rows = $rowsRaw
    }

    foreach ($row in $rows) {
        $rowValues = if ($row -is [string] -or $row -isnot [System.Collections.IEnumerable]) { @($row) } else { @($row) }
        $resourceId = ''
        $rowCost = 0.0
        if ($resourceIdIndex -lt $rowValues.Count) {
            try { $resourceId = [string]$rowValues[$resourceIdIndex] } catch { $resourceId = '' }
        }
        if ($costIndex -lt $rowValues.Count) {
            try { $rowCost = [double]$rowValues[$costIndex] } catch { $rowCost = 0.0 }
        }
        if ([string]::IsNullOrWhiteSpace($resourceId)) { continue }
        $key = $resourceId.Trim().ToLowerInvariant()
        if (-not $costMap.ContainsKey($key)) { $costMap[$key] = 0.0 }
        $costMap[$key] = [double]$costMap[$key] + $rowCost
    }

    return [PSCustomObject]@{
        CostMap   = $costMap
        Currency  = $currency
    }
}

function Get-EstimatedMonthlyCost {
    param (
        [string] $ResourceId,
        [hashtable] $CostMap
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return 0.0 }
    $costKey = $ResourceId.ToLowerInvariant()
    if (-not $CostMap.ContainsKey($costKey)) { return 0.0 }
    return [math]::Round([double]$CostMap[$costKey], 2)
}

function Get-FinOpsToolVersion {
    $loadedModule = Get-Module -Name 'AzureAnalyzer' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($loadedModule -and $loadedModule.PSObject.Properties['Version'] -and $loadedModule.Version) {
        return [string]$loadedModule.Version
    }

    $manifestPath = Join-Path $PSScriptRoot '..' 'AzureAnalyzer.psd1'
    if (Test-Path $manifestPath) {
        try {
            $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
            if ($manifest -and $manifest.Version) { return [string]$manifest.Version }
        } catch {
        }
    }

    return ''
}

function Get-FinOpsRecommendationText {
    param (
        [string] $DetectionCategory,
        [string] $RuleId
    )

    $key = ("$DetectionCategory|$RuleId").ToLowerInvariant()
    if ($key -match 'appserviceplanidlecpumetricsdegraded') {
        return 'Grant Monitoring Reader on the App Service Plan scope, ensure Az.Monitor is available, then rerun FinOps idle CPU analysis.'
    }
    if ($key -match 'appserviceplanidlecpu') {
        return 'Rightsize the App Service Plan SKU/instance count or consolidate workloads when CPU remains below 5 percent.'
    }
    if ($key -match 'unattached|disk|snapshot') {
        return 'Delete orphaned storage artifacts or move them to lower-cost tiers if retention is required.'
    }
    if ($key -match 'virtual machine|stopped|deallocated|idle') {
        return 'Deallocate and delete idle compute resources, or downsize to the smallest SKU that meets demand.'
    }
    if ($key -match 'public ip|empty resource groups') {
        return 'Remove unused networking resources and empty containers to avoid persistent standing charges.'
    }
    if ($key -match 'network controls|load balancer|nsg') {
        return 'Review architecture and remove or redesign premium networking controls that have no active data path.'
    }
    return 'Review whether this resource can be deleted, downscaled, or rightsized.'
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'finops'
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
if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.ResourceGraph module not installed. Run: Install-Module Az.ResourceGraph -Scope CurrentUser'
    return [PSCustomObject]$result
}

Import-Module Az.Accounts -ErrorAction SilentlyContinue
Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue

if (-not (Get-Module -ListAvailable -Name Az.CostManagement)) {
    Write-Verbose '[finops] Az.CostManagement module not installed. Cost Management REST query will be used via Az.Accounts context.'
}

try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { Write-Error 'No Az context' -ErrorAction Stop }
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [PSCustomObject]$result
}

if (-not $QueryFiles -or $QueryFiles.Count -eq 0) {
    $queryRoot = Join-Path $PSScriptRoot '..' 'queries' 'finops'
    $QueryFiles = @(Get-ChildItem -Path $queryRoot -Filter 'finops-*.json' -File | Select-Object -ExpandProperty FullName)
}
if ($QueryFiles.Count -eq 0) {
    $result.Status = 'Skipped'
    $result.Message = 'No FinOps query files found (queries/finops/finops-*.json).'
    return [PSCustomObject]$result
}

$costMap = @{}
$currency = ''
$costError = $null
try {
    $costResult = Get-CostMap -SubscriptionId $SubscriptionId
    $costMap = $costResult.CostMap
    $currency = $costResult.Currency
} catch {
    $costError = Remove-Credentials -Text ([string]$_.Exception.Message)
}

$findings = [System.Collections.Generic.List[object]]::new()
$queryErrors = [System.Collections.Generic.List[string]]::new()
$executedQueryCount = 0
$toolVersion = Get-FinOpsToolVersion

foreach ($queryFile in $QueryFiles) {
    try {
        $queryDoc = Get-Content -Path $queryFile -Raw | ConvertFrom-Json -Depth 20
        $queries = @($queryDoc.queries | Where-Object { $_.queryable -eq $true -and $_.graph })
        foreach ($queryItem in $queries) {
            $executedQueryCount++
            $rawGraph = [string]$queryItem.graph
            # Validated integer substitution (ValidateRange on parameter prevents KQL injection).
            $effectiveGraph = $rawGraph.Replace('{{SnapshotAgeThresholdDays}}', [string]$SnapshotAgeThresholdDays)
            $rows = Invoke-SearchAzGraphAllResults -Query $effectiveGraph -SubscriptionId $SubscriptionId
            foreach ($row in $rows) {
                $compliant = $true
                if ($row.PSObject.Properties['compliant']) {
                    $compliantValue = $row.compliant
                    $compliant = -not ($compliantValue -eq $false -or $compliantValue -eq 0 -or [string]$compliantValue -eq 'false')
                }
                if ($compliant) { continue }

                $resourceId = ''
                if ($row.PSObject.Properties['id'] -and $row.id) { $resourceId = [string]$row.id }
                $resourceName = if ($row.PSObject.Properties['name']) { [string]$row.name } else { '' }
                $resourceType = if ($row.PSObject.Properties['type']) { [string]$row.type } else { '' }
                $resourceGroup = if ($row.PSObject.Properties['resourceGroup']) { [string]$row.resourceGroup } else { '' }
                $location = if ($row.PSObject.Properties['location']) { [string]$row.location } else { '' }
                $titleText = [string]$queryItem.text
                $titleText = $titleText.Replace('{{SnapshotAgeThresholdDays}}', [string]$SnapshotAgeThresholdDays)
                $detailReason = if ($row.PSObject.Properties['detectedReason'] -and $row.detectedReason) {
                    [string]$row.detectedReason
                } else {
                    $titleText
                }
                $rawSeverity = if ($queryItem.PSObject.Properties['severity'] -and $queryItem.severity) { [string]$queryItem.severity } else { 'Info' }
                $ruleId = if ($queryItem.PSObject.Properties['ruleId'] -and $queryItem.ruleId) { [string]$queryItem.ruleId } else { '' }

                $estimatedMonthlyCost = Get-EstimatedMonthlyCost -ResourceId $resourceId -CostMap $costMap
                $costDetail = if ($estimatedMonthlyCost -gt 0) {
                    " Estimated waste: $estimatedMonthlyCost $currency/mo."
                } else {
                    ' Estimated waste unavailable from Cost Management data.'
                }

                $findingIdBase = if (-not [string]::IsNullOrWhiteSpace($resourceId)) { $resourceId } else { [guid]::NewGuid().ToString() }
                $findingId = "finops/$([string]$queryItem.guid)/$($findingIdBase.ToLowerInvariant())"
                $detectionCategory = if ($queryItem.subcategory) { [string]$queryItem.subcategory } else { [string]$queryItem.category }
                $recommendationText = Get-FinOpsRecommendationText -DetectionCategory $detectionCategory -RuleId $ruleId
                $findings.Add([PSCustomObject]@{
                    Id                   = $findingId
                    Source               = 'finops'
                    Category             = 'Cost'
                    Severity             = $rawSeverity
                    RuleId               = $ruleId
                    Compliant            = $false
                    Title                = $titleText
                    Detail               = "$detailReason$costDetail"
                    ResourceId           = $resourceId
                    ResourceType         = $resourceType
                    ResourceName         = $resourceName
                    ResourceGroup        = $resourceGroup
                    SubscriptionId       = $SubscriptionId
                    Location             = $location
                    DetectionCategory    = $detectionCategory
                    EstimatedMonthlyCost = $estimatedMonthlyCost
                    Currency             = $currency
                    LearnMoreUrl         = 'https://learn.microsoft.com/azure/cost-management-billing/costs/cost-mgt-best-practices'
                    QueryId              = [string]$queryItem.guid
                    Recommendation       = $recommendationText
                    ToolVersion          = $toolVersion
                }) | Out-Null
            }
        }
    } catch {
        $queryErrors.Add((Remove-Credentials -Text "Query file $queryFile failed: $([string]$_.Exception.Message)")) | Out-Null
    }
}

try {
    $metricWindowEnd = (Get-Date).ToUniversalTime()
    $metricWindowStart = $metricWindowEnd.AddDays(-30)
    $serverFarmQuery = "resources | where type =~ 'microsoft.web/serverfarms' | project id, name, type, resourceGroup, subscriptionId, location"
    $appServicePlans = @(Invoke-SearchAzGraphAllResults -Query $serverFarmQuery -SubscriptionId $SubscriptionId)
    $cpuMetricName = 'CpuPercentage'
    $metricTimeGrain = [timespan]::FromDays(1)
    $canCollectMetrics = $null -ne (Get-Command Get-AzMetric -ErrorAction SilentlyContinue)

    foreach ($plan in $appServicePlans) {
        if (-not $plan) { continue }
        $resourceId = if ($plan.PSObject.Properties['id']) { [string]$plan.id } else { '' }
        if ([string]::IsNullOrWhiteSpace($resourceId)) { continue }

        $resourceName = if ($plan.PSObject.Properties['name']) { [string]$plan.name } else { '' }
        $resourceType = if ($plan.PSObject.Properties['type']) { [string]$plan.type } else { 'microsoft.web/serverfarms' }
        $resourceGroup = if ($plan.PSObject.Properties['resourceGroup']) { [string]$plan.resourceGroup } else { '' }
        $location = if ($plan.PSObject.Properties['location']) { [string]$plan.location } else { '' }
        $estimatedMonthlyCost = Get-EstimatedMonthlyCost -ResourceId $resourceId -CostMap $costMap
        $costDetail = if ($estimatedMonthlyCost -gt 0) {
            " Estimated waste: $estimatedMonthlyCost $currency/mo."
        } else {
            ' Estimated waste unavailable from Cost Management data.'
        }

        if (-not $canCollectMetrics) {
            $degradedDetectionCategory = 'AppServicePlanIdleCpuMetricsDegraded'
            $degradedRecommendation = Get-FinOpsRecommendationText -DetectionCategory $degradedDetectionCategory -RuleId 'finops-appserviceplan-idle-cpu'
            $findings.Add([PSCustomObject]@{
                    Id                   = "finops/AppServicePlanIdleCpuMetricsDegraded/$($resourceId.ToLowerInvariant())"
                    Source               = 'finops'
                    Category             = 'Cost'
                    Severity             = 'Info'
                    RuleId               = 'finops-appserviceplan-idle-cpu'
                    Compliant            = $false
                    Title                = 'App Service Plan CPU signal collection degraded'
                    Detail               = "Could not collect Azure Monitor CPU metrics for this App Service Plan because Get-AzMetric is unavailable. Install Az.Monitor or use az monitor metrics list for CpuPercentage.$costDetail"
                    ResourceId           = $resourceId
                    ResourceType         = $resourceType
                    ResourceName         = $resourceName
                    ResourceGroup        = $resourceGroup
                    SubscriptionId       = $SubscriptionId
                    Location             = $location
                    DetectionCategory    = $degradedDetectionCategory
                    EstimatedMonthlyCost = $estimatedMonthlyCost
                    Currency             = $currency
                    LearnMoreUrl         = 'https://learn.microsoft.com/azure/azure-monitor/essentials/metrics-supported#microsoftwebserverfarms'
                    QueryId              = 'AppServicePlanIdleCpu'
                    Recommendation       = $degradedRecommendation
                    ToolVersion          = $toolVersion
                }) | Out-Null
            continue
        }

        try {
            $metricResult = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
                Get-AzMetric -ResourceId $resourceId -MetricName $cpuMetricName -TimeGrain $metricTimeGrain -StartTime $metricWindowStart -EndTime $metricWindowEnd -AggregationType Average -ErrorAction Stop
            }
            $samples = [System.Collections.Generic.List[double]]::new()
            $metricData = @()
            if ($metricResult -and $metricResult.PSObject.Properties['Data']) {
                $metricData = @($metricResult.Data)
            }
            foreach ($sample in $metricData) {
                if (-not $sample -or $null -eq $sample.Average) { continue }
                try { $samples.Add([double]$sample.Average) | Out-Null } catch { }
            }
            if ($samples.Count -eq 0) { continue }

            $cpuAverage = [math]::Round((($samples | Measure-Object -Average).Average), 2)
            if ($cpuAverage -ge 5.0) { continue }

            $idleDetectionCategory = 'AppServicePlanIdleCpu'
            $idleRecommendation = Get-FinOpsRecommendationText -DetectionCategory $idleDetectionCategory -RuleId 'finops-appserviceplan-idle-cpu'
            $findings.Add([PSCustomObject]@{
                    Id                   = "finops/AppServicePlanIdleCpu/$($resourceId.ToLowerInvariant())"
                    Source               = 'finops'
                    Category             = 'Cost'
                    Severity             = 'Low'
                    RuleId               = 'finops-appserviceplan-idle-cpu'
                    Compliant            = $false
                    Title                = 'App Service Plan CPU average below 5% over 30 days'
                    Detail               = "App Service Plan CPU average is $cpuAverage% over the last 30 days (threshold <5%). The plan may be oversized or idle.$costDetail"
                    ResourceId           = $resourceId
                    ResourceType         = $resourceType
                    ResourceName         = $resourceName
                    ResourceGroup        = $resourceGroup
                    SubscriptionId       = $SubscriptionId
                    Location             = $location
                    DetectionCategory    = $idleDetectionCategory
                    EstimatedMonthlyCost = $estimatedMonthlyCost
                    Currency             = $currency
                    LearnMoreUrl         = 'https://learn.microsoft.com/azure/app-service/overview-manage-costs'
                    QueryId              = 'AppServicePlanIdleCpu'
                    Recommendation       = $idleRecommendation
                    ToolVersion          = $toolVersion
                }) | Out-Null
        } catch {
            $metricError = Remove-Credentials -Text ([string]$_.Exception.Message)
            $degradedDetectionCategory = 'AppServicePlanIdleCpuMetricsDegraded'
            $degradedRecommendation = Get-FinOpsRecommendationText -DetectionCategory $degradedDetectionCategory -RuleId 'finops-appserviceplan-idle-cpu'
            $findings.Add([PSCustomObject]@{
                    Id                   = "finops/AppServicePlanIdleCpuMetricsDegraded/$($resourceId.ToLowerInvariant())"
                    Source               = 'finops'
                    Category             = 'Cost'
                    Severity             = 'Info'
                    RuleId               = 'finops-appserviceplan-idle-cpu'
                    Compliant            = $false
                    Title                = 'App Service Plan CPU signal collection degraded'
                    Detail               = "Could not collect Azure Monitor CpuPercentage metrics for the last 30 days. Continuing without this signal. Details: $metricError$costDetail"
                    ResourceId           = $resourceId
                    ResourceType         = $resourceType
                    ResourceName         = $resourceName
                    ResourceGroup        = $resourceGroup
                    SubscriptionId       = $SubscriptionId
                    Location             = $location
                    DetectionCategory    = $degradedDetectionCategory
                    EstimatedMonthlyCost = $estimatedMonthlyCost
                    Currency             = $currency
                    LearnMoreUrl         = 'https://learn.microsoft.com/azure/azure-monitor/metrics/metrics-troubleshoot'
                    QueryId              = 'AppServicePlanIdleCpu'
                    Recommendation       = $degradedRecommendation
                    ToolVersion          = $toolVersion
                }) | Out-Null
        }
    }
} catch {
    $queryErrors.Add((Remove-Credentials -Text "App Service Plan CPU signal discovery failed: $([string]$_.Exception.Message)")) | Out-Null
}

$result.Findings = @($findings)
if ($queryErrors.Count -gt 0 -or $costError) {
    if ($findings.Count -gt 0) {
        $result.Status = 'PartialSuccess'
    } else {
        $result.Status = 'Failed'
    }
}

$messages = [System.Collections.Generic.List[string]]::new()
$messages.Add("Executed $executedQueryCount FinOps query definition(s); emitted $($findings.Count) non-compliant signal(s).") | Out-Null
if ($costError) { $messages.Add("Cost enrichment unavailable: $costError") | Out-Null }
if ($queryErrors.Count -gt 0) { $messages.Add(($queryErrors -join ' | ')) | Out-Null }
$result.Message = $messages -join ' '
$result.ToolVersion = $toolVersion

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $rawPath = Join-Path $OutputPath "finops-$SubscriptionId-$(Get-Date -Format yyyyMMddHHmmss).json"
        Set-Content -Path $rawPath -Value (Remove-Credentials ($result | ConvertTo-Json -Depth 20)) -Encoding utf8
    } catch {
        Write-Warning "Failed to write FinOps JSON output: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [PSCustomObject]$result
