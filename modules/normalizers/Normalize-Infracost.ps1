#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Infracost wrapper output.
.DESCRIPTION
    Converts v1 Infracost wrapper output to v2 FindingRow objects.

    Design:
    - One finding per estimated IaC resource (more actionable than one summary).
    - EntityType is AzureResource for report consistency.
    - Because IaC pre-deploy estimates do not have deployed ARM IDs yet, this
      normalizer generates a deterministic synthetic ARM-style resource ID.
    - Severity heuristic is monthly-cost based:
        > 1000 => High
        > 100  => Medium
        else   => Low
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function ConvertTo-InfracostSlug {
    param([string]$Value)
    $slug = if ($Value) { $Value.ToLowerInvariant() } else { 'unknown' }
    $slug = $slug -replace '[^a-z0-9\-]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'unknown' }
    return $slug
}

function Resolve-InfracostSeverity {
    param([double]$MonthlyCost)
    if ($MonthlyCost -gt 1000) { return 'High' }
    if ($MonthlyCost -gt 100) { return 'Medium' }
    return 'Low'
}

function Normalize-Infracost {
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
    $syntheticSub = '00000000-0000-0000-0000-000000000000'

    foreach ($finding in @($ToolResult.Findings)) {
        if (-not $finding) { continue }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $resourceType = if ($finding.PSObject.Properties['ResourceType'] -and $finding.ResourceType) {
            [string]$finding.ResourceType
        } else {
            'unknown'
        }
        $resourceName = if ($finding.PSObject.Properties['ResourceName'] -and $finding.ResourceName) {
            [string]$finding.ResourceName
        } else {
            $findingId
        }
        $projectName = if ($finding.PSObject.Properties['ProjectName'] -and $finding.ProjectName) {
            [string]$finding.ProjectName
        } else {
            'project'
        }

        $monthlyCost = 0.0
        if ($finding.PSObject.Properties['MonthlyCost'] -and $null -ne $finding.MonthlyCost) {
            try {
                $monthlyCost = [double]$finding.MonthlyCost
            } catch {
                $monthlyCost = 0.0
            }
        }
        $currency = if ($finding.PSObject.Properties['Currency'] -and $finding.Currency) {
            [string]$finding.Currency
        } else {
            'USD'
        }

        $resourceSlug = ConvertTo-InfracostSlug -Value "$projectName-$resourceType-$resourceName"
        $syntheticArmId = "/subscriptions/$syntheticSub/resourceGroups/infracost-iac/providers/Microsoft.Infracost/iacResources/$resourceSlug"
        $canonicalId = $syntheticArmId.ToLowerInvariant()
        try {
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $syntheticArmId -EntityType 'AzureResource').CanonicalId
        } catch {
            # Keep synthetic ARM id as fallback.
        }

        $severity = Resolve-InfracostSeverity -MonthlyCost $monthlyCost
        $title = "Estimated monthly cost: $([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $monthlyCost)) for $resourceType"
        $detail = if ($finding.PSObject.Properties['ProjectPath'] -and $finding.ProjectPath) {
            "Resource $resourceName from $($finding.ProjectPath). Static IaC estimate generated before deployment."
        } else {
            "Resource $resourceName from project $projectName. Static IaC estimate generated before deployment."
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'infracost' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant ($monthlyCost -le 100) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'WAF Cost Optimization' -Severity $severity `
            -Detail $detail `
            -Remediation 'Review right-sizing, SKU selection, and environment count before deployment.' `
            -LearnMoreUrl 'https://www.infracost.io/docs/' `
            -ResourceId $syntheticArmId `
            -SubscriptionId $syntheticSub `
            -ResourceGroup 'infracost-iac'
        if ($null -eq $row) { continue }

        $row | Add-Member -NotePropertyName MonthlyCost -NotePropertyValue ([math]::Round($monthlyCost, 2)) -Force
        $row | Add-Member -NotePropertyName Currency -NotePropertyValue $currency -Force
        $normalized.Add($row)
    }

    return @($normalized)
}
