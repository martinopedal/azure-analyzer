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

function Get-ImpactFromUsagePercent {
    param([double] $UsagePercent)
    if ($UsagePercent -ge 90.0) { return 'High' }
    if ($UsagePercent -ge 75.0) { return 'Medium' }
    return 'Low'
}

function Get-EffortForQuotaType {
    param(
        [string] $Service,
        [string] $MetricName
    )

    $normalizedService = ([string]$Service).Trim().ToLowerInvariant()
    $normalizedMetric = ([string]$MetricName).Trim().ToLowerInvariant()

    if ($normalizedService -eq 'network') { return 'Low' }
    if ($normalizedService -eq 'vm') {
        if ($normalizedMetric -like '*family*') { return 'Medium' }
        return 'Medium'
    }
    return 'Medium'
}

function Get-EvidenceUrisForQuotaType {
    param(
        [string] $Service,
        [string] $MetricName
    )

    $normalizedService = ([string]$Service).Trim().ToLowerInvariant()
    $normalizedMetric = ([string]$MetricName).Trim().ToLowerInvariant()
    if ($normalizedService -eq 'vm') {
        return @('https://learn.microsoft.com/azure/virtual-machines/quotas')
    }
    if ($normalizedService -eq 'network') {
        if ($normalizedMetric -like '*publicip*') {
            return @('https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#networking-limits')
        }
        return @('https://learn.microsoft.com/azure/networking/networking-quotas')
    }
    return @('https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits')
}

function Get-QuotaPortalDeepLinkUrl {
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][string] $Service
    )

    $encodedSub = [uri]::EscapeDataString($SubscriptionId)
    $encodedLocation = [uri]::EscapeDataString($Location)
    $encodedService = [uri]::EscapeDataString($Service)
    return "https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas/subscriptionId/$encodedSub/regionName/$encodedLocation/serviceId/$encodedService"
}

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

        $location = if ($f.PSObject.Properties['Location']) { [string]$f.Location } else { 'unknown-region' }
        $provider = if ($f.PSObject.Properties['Service'] -and $f.Service) { [string]$f.Service } else { 'unknown' }
        $entityArmId = "/subscriptions/$($subscriptionId.ToLowerInvariant())/providers/microsoft.capacity/locations/$($location.ToLowerInvariant())/serviceId/$($provider.ToLowerInvariant())"
        try {
            $canonical = ConvertTo-CanonicalEntityId -RawId $entityArmId -EntityType 'AzureResource'
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
        $impact = Get-ImpactFromUsagePercent -UsagePercent $usagePercent
        $effort = Get-EffortForQuotaType -Service $provider -MetricName $quotaId
        $evidenceUris = @(Get-EvidenceUrisForQuotaType -Service $provider -MetricName $quotaId)
        $deepLinkUrl = Get-QuotaPortalDeepLinkUrl -SubscriptionId $subscriptionId -Location $location -Service $provider
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) { [string]$f.ToolVersion } elseif ($ToolResult.PSObject.Properties['ToolVersion']) { [string]$ToolResult.ToolVersion } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'azure-quota' -EntityId $entityId -EntityType 'AzureResource' `
            -Title $title -RuleId $ruleId `
            -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'Capacity' -Severity $severity `
            -Detail $detail -SubscriptionId $subscriptionId `
            -Pillar 'Reliability' -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -ScoreDelta $usagePercent `
            -EvidenceUris $evidenceUris -EntityRefs @($subscriptionId, $location) `
            -ToolVersion $toolVersion -LearnMoreUrl $(if ($evidenceUris.Count -gt 0) { $evidenceUris[0] } else { '' })

        if ($null -eq $row) { continue }

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

