#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Azure Consumption usageDetails cost collection.
.DESCRIPTION
    Queries Microsoft.Consumption usageDetails for the last N days, aggregates
    subscription total spend, and returns top costly resources.
    Never throws.
.PARAMETER SubscriptionId
    Azure subscription ID.
.PARAMETER Days
    Lookback window in days. Defaults to 30.
.PARAMETER TopCount
    Number of costly resources to return. Defaults to 20.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [ValidateRange(1, 365)]
    [int] $Days = 30,

    [ValidateRange(1, 200)]
    [int] $TopCount = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
    Write-Warning "Invoke-AzRestMethod not available. Skipping Azure cost collection. Install/Import Az.Accounts."
    return [PSCustomObject]@{
        Source            = 'azure-cost'
        Status            = 'Skipped'
        Message           = 'Invoke-AzRestMethod not available'
        SubscriptionId    = $SubscriptionId
        Days              = $Days
        Currency          = ''
        SubscriptionTotal = $null
        ResourceCosts     = @()
        Findings          = @()
    }
}

function Get-FieldValue {
    param (
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return $prop.Value
        }
    }

    return $null
}

try {
    $endDate = (Get-Date).Date
    $startDate = $endDate.AddDays(-1 * $Days)
    $start = $startDate.ToString('yyyy-MM-dd')
    $end = $endDate.ToString('yyyy-MM-dd')
    $filter = [System.Uri]::EscapeDataString("properties/usageStart ge '$start' and properties/usageEnd le '$end'")

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/usageDetails?api-version=2024-08-01&`$filter=$filter"
    $usageRows = [System.Collections.Generic.List[object]]::new()

    while ($uri) {
        $response = Invoke-AzRestMethod -Method GET -Uri $uri -ErrorAction Stop
        if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.Content)) { break }
        $parsed = $response.Content | ConvertFrom-Json -ErrorAction Stop
        foreach ($row in @($parsed.value)) {
            if ($row) { $usageRows.Add($row) }
        }
        $uri = if ($parsed.PSObject.Properties['nextLink']) { [string]$parsed.nextLink } else { $null }
    }

    if ($usageRows.Count -eq 0) {
        return [PSCustomObject]@{
            Source            = 'azure-cost'
            Status            = 'Skipped'
            Message           = 'No consumption cost data returned for the selected window'
            SubscriptionId    = $SubscriptionId
            Days              = $Days
            Currency          = ''
            SubscriptionTotal = $null
            ResourceCosts     = @()
            Findings          = @()
        }
    }

    $resourceAgg = @{}
    [double]$subscriptionTotal = 0.0
    $billingCurrency = ''

    foreach ($row in $usageRows) {
        $properties = $row.PSObject.Properties['properties']
        if (-not $properties -or -not $properties.Value) { continue }
        $p = $properties.Value

        $costRaw = Get-FieldValue -Object $p -Names @('costInBillingCurrency', 'pretaxCost', 'cost')
        if ($null -eq $costRaw) { continue }

        [double]$cost = 0.0
        if (-not [double]::TryParse([string]$costRaw, [ref]$cost)) { continue }
        if ($cost -lt 0) { continue }

        $subscriptionTotal += $cost

        if (-not $billingCurrency) {
            $currencyRaw = Get-FieldValue -Object $p -Names @('billingCurrency', 'billingCurrencyCode', 'currency')
            if ($currencyRaw) { $billingCurrency = [string]$currencyRaw }
        }

        $resourceId = Get-FieldValue -Object $p -Names @('instanceId', 'resourceId')
        if (-not $resourceId) { continue }
        $resourceId = [string]$resourceId
        $resourceName = Get-FieldValue -Object $p -Names @('instanceName', 'resourceName')
        if (-not $resourceName) { $resourceName = $resourceId }

        $key = $resourceId.ToLowerInvariant()
        if (-not $resourceAgg.ContainsKey($key)) {
            $resourceAgg[$key] = [PSCustomObject]@{
                ResourceId   = $resourceId
                ResourceName = [string]$resourceName
                MonthlyCost  = 0.0
                Currency     = ''
            }
        }
        $resourceAgg[$key].MonthlyCost = [double]$resourceAgg[$key].MonthlyCost + $cost
        if (-not $resourceAgg[$key].Currency -and $billingCurrency) {
            $resourceAgg[$key].Currency = $billingCurrency
        }
    }

    if ($subscriptionTotal -le 0 -and $resourceAgg.Count -eq 0) {
        return [PSCustomObject]@{
            Source            = 'azure-cost'
            Status            = 'Skipped'
            Message           = 'No billable consumption data found for the selected window'
            SubscriptionId    = $SubscriptionId
            Days              = $Days
            Currency          = $billingCurrency
            SubscriptionTotal = $null
            ResourceCosts     = @()
            Findings          = @()
        }
    }

    $topResources = @($resourceAgg.Values | Sort-Object -Property MonthlyCost -Descending | Select-Object -First $TopCount)
    foreach ($res in $topResources) {
        if (-not $res.Currency -and $billingCurrency) {
            $res.Currency = $billingCurrency
        }
    }

    return [PSCustomObject]@{
        Source            = 'azure-cost'
        Status            = 'Success'
        Message           = ''
        SubscriptionId    = $SubscriptionId
        Days              = $Days
        Currency          = $billingCurrency
        SubscriptionTotal = [Math]::Round($subscriptionTotal, 2)
        ResourceCosts     = $topResources
        Findings          = @()
    }
} catch {
    Write-Warning "Azure cost collection failed: $_"
    return [PSCustomObject]@{
        Source            = 'azure-cost'
        Status            = 'Failed'
        Message           = "$_"
        SubscriptionId    = $SubscriptionId
        Days              = $Days
        Currency          = ''
        SubscriptionTotal = $null
        ResourceCosts     = @()
        Findings          = @()
    }
}
