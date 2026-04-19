#requires -Version 7.0
<#
.SYNOPSIS
    FinOps signals wrapper - detect likely idle or unused Azure resources.

.DESCRIPTION
    Correlates Azure Resource Graph signals from queries/finops-*.json with monthly
    resource-level cost data from the Cost Management query API. Emits a standard v1
    wrapper envelope consumed by Normalize-FinOpsSignals.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string[]] $QueryFiles,
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
        throw "Cost Management query failed with status $($resp.StatusCode)."
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
        throw "Cost Management response missing expected ResourceId/Cost columns."
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
    Write-Warning 'Az.CostManagement module not installed. Cost Management REST query will be used via Az.Accounts context.'
}

try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No Az context' }
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [PSCustomObject]$result
}

if (-not $QueryFiles -or $QueryFiles.Count -eq 0) {
    $queryRoot = Join-Path $PSScriptRoot '..' 'queries'
    $QueryFiles = @(Get-ChildItem -Path $queryRoot -Filter 'finops-*.json' -File | Select-Object -ExpandProperty FullName)
}
if ($QueryFiles.Count -eq 0) {
    $result.Status = 'Skipped'
    $result.Message = 'No FinOps query files found (queries/finops-*.json).'
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

foreach ($queryFile in $QueryFiles) {
    try {
        $queryDoc = Get-Content -Path $queryFile -Raw | ConvertFrom-Json -Depth 20
        $queries = @($queryDoc.queries | Where-Object { $_.queryable -eq $true -and $_.graph })
        foreach ($queryItem in $queries) {
            $executedQueryCount++
            $rows = Invoke-SearchAzGraphAllResults -Query ([string]$queryItem.graph) -SubscriptionId $SubscriptionId
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
                $detailReason = if ($row.PSObject.Properties['detectedReason'] -and $row.detectedReason) {
                    [string]$row.detectedReason
                } else {
                    [string]$queryItem.text
                }

                $estimatedMonthlyCost = 0.0
                if (-not [string]::IsNullOrWhiteSpace($resourceId)) {
                    $costKey = $resourceId.ToLowerInvariant()
                    if ($costMap.ContainsKey($costKey)) {
                        $estimatedMonthlyCost = [math]::Round([double]$costMap[$costKey], 2)
                    }
                }
                $costDetail = if ($estimatedMonthlyCost -gt 0) {
                    " Estimated waste: $estimatedMonthlyCost $currency/mo."
                } else {
                    ' Estimated waste unavailable from Cost Management data.'
                }

                $findingIdBase = if (-not [string]::IsNullOrWhiteSpace($resourceId)) { $resourceId } else { [guid]::NewGuid().ToString() }
                $findingId = "finops/$([string]$queryItem.guid)/$($findingIdBase.ToLowerInvariant())"
                $findings.Add([PSCustomObject]@{
                    Id                   = $findingId
                    Source               = 'finops'
                    Category             = 'Cost'
                    Severity             = 'Info'
                    Compliant            = $false
                    Title                = [string]$queryItem.text
                    Detail               = "$detailReason$costDetail"
                    ResourceId           = $resourceId
                    ResourceType         = $resourceType
                    ResourceName         = $resourceName
                    ResourceGroup        = $resourceGroup
                    SubscriptionId       = $SubscriptionId
                    Location             = $location
                    DetectionCategory    = if ($queryItem.subcategory) { [string]$queryItem.subcategory } else { [string]$queryItem.category }
                    EstimatedMonthlyCost = $estimatedMonthlyCost
                    Currency             = $currency
                    LearnMoreUrl         = 'https://learn.microsoft.com/azure/cost-management-billing/costs/cost-mgt-best-practices'
                    QueryId              = [string]$queryItem.guid
                }) | Out-Null
            }
        }
    } catch {
        $queryErrors.Add((Remove-Credentials -Text "Query file $queryFile failed: $([string]$_.Exception.Message)")) | Out-Null
    }
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
