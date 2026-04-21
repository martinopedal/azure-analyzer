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

function ConvertTo-InfracostDouble {
    param(
        [AllowNull()][object]$Value,
        [Nullable[double]]$Default = $null
    )
    if ($null -eq $Value) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return [double]$parsed
    }
    return $Default
}

function Resolve-InfracostImpact {
    param(
        [double]$MonthlyCost,
        [double]$ProjectTotalMonthlyCost
    )
    if ($ProjectTotalMonthlyCost -le 0) { return 'Low' }
    $percentage = ($MonthlyCost / $ProjectTotalMonthlyCost) * 100
    if ($percentage -ge 30) { return 'High' }
    if ($percentage -ge 10) { return 'Medium' }
    return 'Low'
}

function Resolve-InfracostEffort {
    param([string]$ResourceType)
    $normalized = if ($ResourceType) { $ResourceType.ToLowerInvariant() } else { '' }
    if ($normalized -match 'resource_group|tag|diagnostic') { return 'Low' }
    if ($normalized -match 'storage|app_service_plan|public_ip|disk|redis|servicebus') { return 'Low' }
    if ($normalized -match 'kubernetes|aks|sql|postgres|cosmos|firewall|application_gateway|frontdoor') { return 'Medium' }
    return 'Low'
}

function Convert-ToHashtableArray {
    param([object[]]$Items)
    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in @($Items)) {
        if (-not $item) { continue }
        if ($item -is [hashtable]) {
            $result.Add($item) | Out-Null
            continue
        }
        if ($item -is [System.Collections.IDictionary]) {
            $table = @{}
            foreach ($key in $item.Keys) { $table[[string]$key] = $item[$key] }
            $result.Add($table) | Out-Null
            continue
        }
        $props = $item.PSObject.Properties
        if ($props) {
            $table = @{}
            foreach ($prop in $props) { $table[[string]$prop.Name] = $prop.Value }
            $result.Add($table) | Out-Null
        }
    }
    return @($result)
}

function Convert-ToStringArray {
    param([object[]]$Items)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Items)) {
        if ([string]::IsNullOrWhiteSpace([string]$item)) { continue }
        $result.Add([string]$item) | Out-Null
    }
    return @($result)
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
        $projectTotalMonthlyCost = if ($finding.PSObject.Properties['ProjectTotalMonthlyCost']) {
            ConvertTo-InfracostDouble -Value $finding.ProjectTotalMonthlyCost -Default $monthlyCost
        } elseif ($ToolResult.PSObject.Properties['ToolSummary'] -and $ToolResult.ToolSummary -and $ToolResult.ToolSummary.PSObject.Properties['TotalMonthlyCost']) {
            ConvertTo-InfracostDouble -Value $ToolResult.ToolSummary.TotalMonthlyCost -Default $monthlyCost
        } else {
            $monthlyCost
        }
        $baselineMonthlyCost = if ($finding.PSObject.Properties['BaselineMonthlyCost']) {
            ConvertTo-InfracostDouble -Value $finding.BaselineMonthlyCost -Default 0
        } elseif ($ToolResult.PSObject.Properties['ToolSummary'] -and $ToolResult.ToolSummary -and $ToolResult.ToolSummary.PSObject.Properties['BaselineMonthlyCost']) {
            ConvertTo-InfracostDouble -Value $ToolResult.ToolSummary.BaselineMonthlyCost -Default 0
        } else {
            0
        }
        $scoreDelta = if ($finding.PSObject.Properties['DiffMonthlyCost']) {
            ConvertTo-InfracostDouble -Value $finding.DiffMonthlyCost -Default $null
        } elseif ($ToolResult.PSObject.Properties['ToolSummary'] -and $ToolResult.ToolSummary -and $ToolResult.ToolSummary.PSObject.Properties['DiffMonthlyCost']) {
            ConvertTo-InfracostDouble -Value $ToolResult.ToolSummary.DiffMonthlyCost -Default $null
        } elseif ($baselineMonthlyCost -gt 0) {
            [double]$monthlyCost - [double]$baselineMonthlyCost
        } else {
            $null
        }
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) {
            [string]$finding.Impact
        } else {
            Resolve-InfracostImpact -MonthlyCost $monthlyCost -ProjectTotalMonthlyCost $projectTotalMonthlyCost
        }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) {
            [string]$finding.Effort
        } else {
            Resolve-InfracostEffort -ResourceType $resourceType
        }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Cost' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }
        $remediationSnippets = if ($finding.PSObject.Properties['RemediationSnippets'] -and $finding.RemediationSnippets) { Convert-ToHashtableArray -Items @($finding.RemediationSnippets) } else { @() }
        $evidenceUris = if ($finding.PSObject.Properties['EvidenceUris'] -and $finding.EvidenceUris) { Convert-ToStringArray -Items @($finding.EvidenceUris) } else { @() }
        $entityRefs = if ($finding.PSObject.Properties['EntityRefs'] -and $finding.EntityRefs) { Convert-ToStringArray -Items @($finding.EntityRefs) } else { @() }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) {
            [string]$finding.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) {
            [string]$ToolResult.ToolVersion
        } else {
            ''
        }
        $frameworks = @(
            @{
                kind      = 'WAF'
                controlId = 'Cost'
            }
        )
        $baselineTags = @()
        if ($baselineMonthlyCost -gt 0) {
            $baselineTags = @('infracost:baseline')
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
            -ResourceGroup 'infracost-iac' `
            -Pillar $pillar -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -Frameworks $frameworks -RemediationSnippets $remediationSnippets `
            -EvidenceUris $evidenceUris -BaselineTags $baselineTags -ScoreDelta $scoreDelta `
            -EntityRefs $entityRefs -ToolVersion $toolVersion
        if ($null -eq $row) { continue }

        $row | Add-Member -NotePropertyName MonthlyCost -NotePropertyValue ([math]::Round($monthlyCost, 2)) -Force
        $row | Add-Member -NotePropertyName Currency -NotePropertyValue $currency -Force
        $normalized.Add($row)
    }

    return @($normalized)
}
