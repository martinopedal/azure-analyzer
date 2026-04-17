#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Azure Consumption API — 30-day subscription spend + top costly resources.

.DESCRIPTION
    Queries Microsoft.Consumption/usageDetails for a trailing 30-day window, aggregates
    cost per resource ID, and returns a standardized v1 tool-result shape. The
    Normalize-AzureCost normalizer downstream converts this into v2 FindingRows that
    populate MonthlyCost / Currency / CostTrend on the existing AzureResource entities.

    Uses Invoke-WithRetry for transient 429/503/timeout handling. Gracefully skips
    when the subscription has no consumption data (new sub, trial, CSP without
    Consumption API access).

.PARAMETER SubscriptionId
    Azure subscription ID (GUID). Required.

.PARAMETER TopN
    Number of top costly resources to emit. Default 20 per the acceptance criteria.

.PARAMETER OutputPath
    Optional directory for raw API JSON (for audit).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [ValidateRange(1, 100)] [int] $TopN = 20,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared Retry helper if available
$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'azure-cost'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

# --- Prereq: Az.Accounts authenticated ---
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    return [pscustomobject]$result
}
Import-Module Az.Accounts -ErrorAction SilentlyContinue

try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No Az context' }
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [pscustomobject]$result
}

# --- Build REST URL for Consumption API (list usageDetails) ---
$toDate   = (Get-Date).ToUniversalTime().Date
$fromDate = $toDate.AddDays(-30)
$filter   = "properties/usageStart ge '$($fromDate.ToString('yyyy-MM-dd'))' and properties/usageEnd le '$($toDate.ToString('yyyy-MM-dd'))'"

$uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/usageDetails?api-version=2021-10-01&`$filter=$([System.Uri]::EscapeDataString($filter))&`$top=5000"

$allRecords = [System.Collections.Generic.List[object]]::new()
$currency   = ''
$nextLink   = $uri
$pageCount  = 0
$maxPages   = 20

try {
    while ($nextLink -and $pageCount -lt $maxPages) {
        $pageCount++
        $resp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
            Invoke-AzRestMethod -Method GET -Uri $using:nextLink -ErrorAction Stop
        }
        if (-not $resp -or $resp.StatusCode -ge 400) {
            # 404/204 typically means "no consumption data available" — skip gracefully.
            if ($resp -and $resp.StatusCode -in 204, 404) {
                $result.Status  = 'Skipped'
                $result.Message = "Consumption API returned $($resp.StatusCode) — no cost data for this subscription."
                return [pscustomobject]$result
            }
            throw "Consumption API returned status $($resp.StatusCode): $($resp.Content)"
        }
        $body = $resp.Content | ConvertFrom-Json -Depth 20
        if ($body.value) {
            foreach ($row in $body.value) {
                $allRecords.Add($row) | Out-Null
                if (-not $currency -and $row.properties.billingCurrency) { $currency = $row.properties.billingCurrency }
            }
        }
        $nextLink = $body.nextLink
    }
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Consumption API query failed: $($_.Exception.Message)"
    return [pscustomobject]$result
}

if ($allRecords.Count -eq 0) {
    $result.Status  = 'Skipped'
    $result.Message = 'No cost data returned from Consumption API for this subscription.'
    return [pscustomobject]$result
}

# --- Aggregate per resource + per subscription ---
$byResource = @{}
$subTotal = 0.0
foreach ($r in $allRecords) {
    $rid  = if ($r.properties.instanceId) { $r.properties.instanceId } elseif ($r.properties.resourceId) { $r.properties.resourceId } else { '' }
    $cost = 0.0
    if ($r.properties.cost)             { $cost = [double]$r.properties.cost }
    elseif ($r.properties.costInBillingCurrency) { $cost = [double]$r.properties.costInBillingCurrency }
    $subTotal += $cost
    if (-not $rid) { continue }
    if (-not $byResource.ContainsKey($rid)) {
        $byResource[$rid] = [ordered]@{
            ResourceId   = $rid
            ResourceName = $r.properties.resourceName
            ResourceType = if ($r.properties.consumedService) { $r.properties.consumedService } else { $r.properties.resourceType }
            Location     = $r.properties.resourceLocation
            TotalCost    = 0.0
        }
    }
    $byResource[$rid].TotalCost += $cost
}

$top = @($byResource.Values | Sort-Object -Property TotalCost -Descending | Select-Object -First $TopN)

$findings = [System.Collections.Generic.List[object]]::new()

# Subscription-entity roll-up
$findings.Add([pscustomobject]@{
    Id           = "azure-cost/subscription/$SubscriptionId"
    Source       = 'azure-cost'
    Category     = 'Cost'
    Severity     = 'Info'
    Compliant    = $true
    Title        = "30-day subscription spend: $([math]::Round($subTotal,2)) $currency"
    Detail       = "Aggregated from $($allRecords.Count) usageDetails records for window $($fromDate.ToString('yyyy-MM-dd'))..$($toDate.ToString('yyyy-MM-dd')). Top-$TopN resources follow."
    ResourceId   = "/subscriptions/$SubscriptionId"
    ResourceType = 'Microsoft.Resources/subscriptions'
    MonthlyCost  = [math]::Round($subTotal, 2)
    Currency     = $currency
    CostTrend    = ''
    Remediation  = ''
    LearnMoreUrl = 'https://learn.microsoft.com/azure/cost-management-billing/'
}) | Out-Null

foreach ($item in $top) {
    $findings.Add([pscustomobject]@{
        Id           = "azure-cost/resource/$($item.ResourceId)"
        Source       = 'azure-cost'
        Category     = 'Cost'
        Severity     = 'Info'
        Compliant    = $true
        Title        = "Top costly resource: $([math]::Round($item.TotalCost,2)) $currency"
        Detail       = "$($item.ResourceType) in $($item.Location). 30-day total $([math]::Round($item.TotalCost,2)) $currency."
        ResourceId   = $item.ResourceId
        ResourceType = $item.ResourceType
        ResourceName = $item.ResourceName
        Location     = $item.Location
        MonthlyCost  = [math]::Round($item.TotalCost, 2)
        Currency     = $currency
        CostTrend    = ''
        Remediation  = ''
        LearnMoreUrl = 'https://learn.microsoft.com/azure/advisor/advisor-cost-recommendations'
    }) | Out-Null
}

$result.Findings = @($findings)
$result.Message  = "Collected $($allRecords.Count) usage records; emitted 1 subscription roll-up + $($top.Count) top-resource findings."

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $raw = Join-Path $OutputPath "cost-$SubscriptionId-$(Get-Date -Format yyyyMMddHHmmss).json"
        ($result | ConvertTo-Json -Depth 20) | Set-Content -Path $raw -Encoding utf8
    } catch {
        Write-Warning "Failed to write raw cost JSON: $($_.Exception.Message)"
    }
}

return [pscustomobject]$result
