#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Azure Quota Reports wrapper output.
.DESCRIPTION
    Converts v1 `azure-quota` findings into v2 FindingRows using `New-FindingRow`.
    Severity mapping follows the team decision ladder:
      - UsagePercent >= 99  => Critical
      - UsagePercent >= 95  => High
      - UsagePercent >= threshold => Medium
      - UsagePercent < threshold  => Info
    Compliant is locked to: UsagePercent < Threshold (default 80 when missing).
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-AzureQuotaReports {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($f in $ToolResult.Findings) {
        $subscriptionId = if ($f.PSObject.Properties['SubscriptionId']) { [string]$f.SubscriptionId } else { '' }
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) { continue }

        try {
            $canonical = ConvertTo-CanonicalEntityId -RawId $subscriptionId -EntityType 'Subscription'
            $entityId = $canonical.CanonicalId
        } catch {
            continue
        }

        $threshold = 80.0
        if ($f.PSObject.Properties['Threshold'] -and $null -ne $f.Threshold) {
            $threshold = [double]$f.Threshold
        }

        $usagePercent = 0.0
        if ($f.PSObject.Properties['UsagePercent'] -and $null -ne $f.UsagePercent) {
            $usagePercent = [double]$f.UsagePercent
        }

        $compliant = ($usagePercent -lt $threshold)
        $severity = if ($usagePercent -ge 99.0) {
            'Critical'
        } elseif ($usagePercent -ge 95.0) {
            'High'
        } elseif ($usagePercent -ge $threshold) {
            'Medium'
        } else {
            'Info'
        }

        $location = if ($f.PSObject.Properties['Location']) { [string]$f.Location } else { 'unknown-region' }
        $skuName = if ($f.PSObject.Properties['SkuName'] -and $f.SkuName) {
            [string]$f.SkuName
        } elseif ($f.PSObject.Properties['Sku'] -and $f.Sku) {
            [string]$f.Sku
        } elseif ($f.PSObject.Properties['MetricName'] -and $f.MetricName) {
            [string]$f.MetricName
        } else {
            'unknown-sku'
        }

        $currentValue = if ($f.PSObject.Properties['CurrentValue'] -and $null -ne $f.CurrentValue) { [double]$f.CurrentValue } else { 0.0 }
        $limit = if ($f.PSObject.Properties['Limit'] -and $null -ne $f.Limit) { [double]$f.Limit } else { 0.0 }
        $provider = if ($f.PSObject.Properties['Service'] -and $f.Service) { [string]$f.Service } else { 'unknown' }
        $quotaId = if ($f.PSObject.Properties['QuotaId'] -and $f.QuotaId) {
            [string]$f.QuotaId
        } elseif ($f.PSObject.Properties['MetricName'] -and $f.MetricName) {
            [string]$f.MetricName
        } else {
            $skuName
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $title = "Quota $skuName in $location is at $usagePercent%"
        $detail = "CurrentValue=$currentValue; Limit=$limit; Region=$location; SkuName=$skuName."

        $ruleId = "azure-quota:${provider}:${quotaId}:${location}"

        $row = New-FindingRow -Id $findingId `
            -Source 'azure-quota' -EntityId $entityId -EntityType 'Subscription' `
            -Title $title -RuleId $ruleId `
            -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'Capacity' -Severity $severity `
            -Detail $detail -SubscriptionId $subscriptionId

        if ($null -eq $row) { continue }

        $row | Add-Member -NotePropertyName Pillar -NotePropertyValue 'Reliability' -Force
        foreach ($extra in @(
                'Location',
                'Service',
                'Sku',
                'SkuName',
                'MetricName',
                'CurrentValue',
                'Limit',
                'UsagePercent',
                'Threshold',
                'Unit'
            )) {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}

