#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Azure cost collection findings.
.DESCRIPTION
    Converts aggregated consumption data to informational v2 FindingRows and
    annotates the owning entities with MonthlyCost/Currency metadata.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-AzureCost {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success') {
        return @()
    }

    $subscriptionId = ''
    if ($ToolResult.PSObject.Properties['SubscriptionId'] -and $ToolResult.SubscriptionId) {
        $subscriptionId = [string]$ToolResult.SubscriptionId
    }
    if (-not $subscriptionId) {
        return @()
    }

    $subscriptionTotal = $null
    if ($ToolResult.PSObject.Properties['SubscriptionTotal']) {
        $subscriptionTotal = $ToolResult.SubscriptionTotal
    }
    $resourceCosts = if ($ToolResult.PSObject.Properties['ResourceCosts']) { @($ToolResult.ResourceCosts) } else { @() }
    if ($null -eq $subscriptionTotal -and @($resourceCosts).Count -eq 0) {
        return @()
    }

    $currency = ''
    if ($ToolResult.PSObject.Properties['Currency'] -and $ToolResult.Currency) {
        $currency = [string]$ToolResult.Currency
    }
    $days = if ($ToolResult.PSObject.Properties['Days'] -and $ToolResult.Days) { [int]$ToolResult.Days } else { 30 }
    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    $subscriptionEntityId = "/subscriptions/$($subscriptionId.ToLowerInvariant())"
    if ($null -ne $subscriptionTotal) {
        $amount = [Math]::Round([double]$subscriptionTotal, 2)
        $currencyLabel = if ($currency) { " $currency" } else { '' }
        $detail = "Total subscription spend for the last $days day(s): $amount$currencyLabel."
        $subFinding = New-FindingRow -Id ([guid]::NewGuid().ToString()) `
            -Source 'azure-cost' -EntityId $subscriptionEntityId -EntityType 'Subscription' `
            -Title "Subscription spend (last $days days)" -Compliant $true -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'Cost' -Severity 'Info' `
            -Detail $detail -ResourceId $subscriptionEntityId -SubscriptionId $subscriptionId
        if ($subFinding.PSObject.Properties['MonthlyCost']) {
            $subFinding.MonthlyCost = $amount
        } else {
            $subFinding | Add-Member -MemberType NoteProperty -Name MonthlyCost -Value $amount
        }
        if ($currency) {
            if ($subFinding.PSObject.Properties['Currency']) {
                $subFinding.Currency = $currency
            } else {
                $subFinding | Add-Member -MemberType NoteProperty -Name Currency -Value $currency
            }
        }
        $normalized.Add($subFinding)
    }

    foreach ($resource in $resourceCosts) {
        if (-not $resource) { continue }
        $rawIdProp = $resource.PSObject.Properties['ResourceId']
        if (-not $rawIdProp -or -not $rawIdProp.Value) { continue }
        $rawId = [string]$rawIdProp.Value
        if (-not ($rawId -match '^/subscriptions/')) { continue }

        $canonicalId = ''
        try {
            $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId
        } catch {
            $canonicalId = $rawId.ToLowerInvariant()
        }

        $amount = 0.0
        $costValue = $resource.PSObject.Properties['MonthlyCost']
        if (-not $costValue) { continue }
        if (-not [double]::TryParse([string]$costValue.Value, [ref]$amount)) { continue }
        $amount = [Math]::Round($amount, 2)

        $resourceCurrency = $currency
        $resourceCurrencyProp = $resource.PSObject.Properties['Currency']
        if ($resourceCurrencyProp -and $resourceCurrencyProp.Value) {
            $resourceCurrency = [string]$resourceCurrencyProp.Value
        }

        $resourceName = ''
        $resourceNameProp = $resource.PSObject.Properties['ResourceName']
        if ($resourceNameProp -and $resourceNameProp.Value) {
            $resourceName = [string]$resourceNameProp.Value
        }
        if (-not $resourceName) { $resourceName = $canonicalId }

        $detail = if ($resourceCurrency) {
            "Estimated monthly spend for resource '$resourceName' over the last $days day(s): $amount $resourceCurrency."
        } else {
            "Estimated monthly spend for resource '$resourceName' over the last $days day(s): $amount."
        }

        $subIdFromArm = ''
        $resourceGroup = ''
        if ($canonicalId -match '/subscriptions/([^/]+)') { $subIdFromArm = $Matches[1] }
        if ($canonicalId -match '/resourcegroups/([^/]+)') { $resourceGroup = $Matches[1] }

        $finding = New-FindingRow -Id ([guid]::NewGuid().ToString()) `
            -Source 'azure-cost' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title "Resource spend: $resourceName" -Compliant $true -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'Cost' -Severity 'Info' `
            -Detail $detail -ResourceId $canonicalId -SubscriptionId $subIdFromArm -ResourceGroup $resourceGroup

        if ($finding.PSObject.Properties['MonthlyCost']) {
            $finding.MonthlyCost = $amount
        } else {
            $finding | Add-Member -MemberType NoteProperty -Name MonthlyCost -Value $amount
        }
        if ($resourceCurrency) {
            if ($finding.PSObject.Properties['Currency']) {
                $finding.Currency = $resourceCurrency
            } else {
                $finding | Add-Member -MemberType NoteProperty -Name Currency -Value $resourceCurrency
            }
        }

        $normalized.Add($finding)
    }

    return @($normalized)
}
