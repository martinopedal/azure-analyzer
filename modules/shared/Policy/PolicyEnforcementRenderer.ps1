# PolicyEnforcementRenderer.ps1
# Track C scaffold (#431). Stub only. Implementation lands after Foundation #435.
# Emits Cytoscape JSON for the policy enforcement graph layer (assignments, exemptions,
# inheritance, compliance heatmap). Reuses tier-aware rendering from Track A (#428).

Set-StrictMode -Version Latest

function Invoke-PolicyEnforcementRender {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Entities,
        [Parameter(Mandatory)] [object[]] $Edges,
        [Parameter(Mandatory)] [hashtable] $ComplianceState,
        [int] $Tier = 1
    )
    return New-PolicyEnforcementGraph -Entities $Entities -Edges $Edges -ComplianceState $ComplianceState -Tier $Tier
}

function New-PolicyEnforcementGraph {
    <#
    .SYNOPSIS
        Build the Cytoscape JSON payload for the policy enforcement graph layer.
    .PARAMETER Entities
        v3 entity set (scopes, assignments, definitions, exemptions, resources).
    .PARAMETER Edges
        Edges of relations PolicyAssignedTo, PolicyEnforces, ExemptedFrom, InheritsFrom.
    .PARAMETER ComplianceState
        Per-scope compliance percentages keyed by canonical scope id.
    .PARAMETER Tier
        Render tier (1, 2, 3). Tier 2+ uses query-on-demand (Track V #430).
    .OUTPUTS
        Hashtable shaped for Cytoscape consumption.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Entities,
        [Parameter(Mandatory)] [object[]] $Edges,
        [Parameter(Mandatory)] [hashtable] $ComplianceState,
        [int] $Tier = 1
    )
    $scopeTypes = @('Tenant', 'ManagementGroup', 'Subscription', 'ResourceGroup')
    $nodes = [System.Collections.Generic.List[object]]::new()
    $renderedEntityIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entity in @($Entities)) {
        if ($null -eq $entity) { continue }
        $entityType = if ($entity.PSObject.Properties['EntityType']) { [string]$entity.EntityType } else { '' }
        $entityId = if ($entity.PSObject.Properties['EntityId']) { [string]$entity.EntityId } else { '' }
        if ([string]::IsNullOrWhiteSpace($entityId)) { continue }
        if (-not ($entityType -in $scopeTypes -or $entityType -eq 'PolicyExemption')) { continue }

        $compliance = 100.0
        if ($ComplianceState.ContainsKey($entityId)) {
            $compliance = [double]$ComplianceState[$entityId]
        }
        $label = if ($entity.PSObject.Properties['DisplayName'] -and -not [string]::IsNullOrWhiteSpace([string]$entity.DisplayName)) {
            [string]$entity.DisplayName
        } else {
            $entityId
        }

        $tooltip = ''
        if ($entityType -eq 'PolicyExemption') {
            $tooltip = Format-ExemptionTooltip -Exemption $entity
        }
        $failingAssignments = @()
        if ($entity.PSObject.Properties['FailingAssignments']) {
            $failingAssignments = @($entity.FailingAssignments)
        }

        $nodes.Add([pscustomobject]@{
            data = [pscustomobject]@{
                id                 = $entityId
                label              = $label
                entityType         = $entityType
                compliancePercent  = [Math]::Round($compliance, 2)
                heatmapColor       = Get-ComplianceHeatmapColor -Percent $compliance
                tooltip            = $tooltip
                failingAssignments = @($failingAssignments)
            }
        }) | Out-Null
        $renderedEntityIds.Add($entityId) | Out-Null
    }

    $renderedEdges = [System.Collections.Generic.List[object]]::new()
    foreach ($edge in @($Edges)) {
        if ($null -eq $edge) { continue }
        $source = if ($edge.PSObject.Properties['Source']) { [string]$edge.Source } else { '' }
        $target = if ($edge.PSObject.Properties['Target']) { [string]$edge.Target } else { '' }
        $relation = if ($edge.PSObject.Properties['Relation']) { [string]$edge.Relation } else { '' }
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) { continue }
        if (-not ($relation -in @('PolicyAssignedTo', 'PolicyEnforces', 'ExemptedFrom', 'InheritsFrom'))) { continue }
        if (-not ($renderedEntityIds.Contains($source) -or $renderedEntityIds.Contains($target))) { continue }
        $renderedEdges.Add([pscustomobject]@{
            data = [pscustomobject]@{
                id       = if ($edge.PSObject.Properties['EdgeId']) { [string]$edge.EdgeId } else { "edge:$source|$relation|$target" }
                source   = $source
                target   = $target
                relation = $relation
                style    = [pscustomobject]@{
                    lineStyle = if ($relation -eq 'InheritsFrom') { 'dashed' } else { 'solid' }
                    highlight = ($relation -eq 'ExemptedFrom')
                }
            }
        }) | Out-Null
    }

    return @{
        metadata = @{
            tier = [int]$Tier
            generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        elements = @{
            nodes = @($nodes)
            edges = @($renderedEdges)
        }
    }
}

function Get-ComplianceHeatmapColor {
    <#
    .SYNOPSIS
        Map a compliance percentage [0,100] to one of five sequential heatmap buckets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $Percent
    )
    if ($Percent -ge 100) { return '#2e7d32' }
    if ($Percent -ge 90) { return '#66bb6a' }
    if ($Percent -ge 70) { return '#fdd835' }
    if ($Percent -ge 40) { return '#fb8c00' }
    return '#c62828'
}

function Format-ExemptionTooltip {
    <#
    .SYNOPSIS
        Build the hover tooltip for an exemption node, surfacing expiry and reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Exemption
    )
    $name = if ($Exemption.PSObject.Properties['DisplayName'] -and $Exemption.DisplayName) { [string]$Exemption.DisplayName } else { 'Policy exemption' }
    $reason = if ($Exemption.PSObject.Properties['Reason'] -and $Exemption.Reason) { [string]$Exemption.Reason } else { 'No reason provided' }
    $expires = if ($Exemption.PSObject.Properties['ExpiresOn'] -and $Exemption.ExpiresOn) { [string]$Exemption.ExpiresOn } else { 'No expiry' }
    return "$name`nReason: $reason`nExpires: $expires"
}

if ($MyInvocation.MyCommand.Module) {
    Export-ModuleMember -Function Invoke-PolicyEnforcementRender, New-PolicyEnforcementGraph, Get-ComplianceHeatmapColor, Format-ExemptionTooltip
}
