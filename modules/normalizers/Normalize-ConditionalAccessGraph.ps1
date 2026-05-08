#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for the conditional-access-graph wrapper (graph mapping R1).
.DESCRIPTION
    Converts the v1 wrapper envelope from
    Invoke-ConditionalAccessGraph.ps1 into:

      * v2 FindingRow objects (via New-FindingRow) for each policy-risk
        finding emitted by the wrapper.
      * v3 Edge objects (via New-Edge) for AppliesTo / Excludes
        relationships between the ConditionalAccessPolicy and the User /
        Group / Application / NamedLocation entities it gates.

    The normalizer returns a flat array of v2 FindingRow objects. When
    the caller passes -EdgeCollector, AppliesTo / Excludes edges for the
    User / Group / Application / NamedLocation entities the policy gates
    are appended to that list for the orchestrator to drain into the
    EntityStore. This matches the flat-array + edge-collector contract
    used by the rest of the graph-mapping family.

    Domain=IdentityGraph, Pillar=Identity.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"
. "$PSScriptRoot\..\shared\Sanitize.ps1"

# Microsoft Graph "All" sentinels are not entity IDs; skip them when
# emitting edges so we do not clutter the graph with synthetic vertices.
$script:CaSentinels = @('All', 'None', 'GuestsOrExternalUsers')

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    if (-not $Obj.PSObject.Properties[$Name]) { return $Default }
    $v = $Obj.PSObject.Properties[$Name].Value
    if ($null -eq $v) { return $Default }
    return $v
}

function Test-IsGuid {
    param ([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    # Use the framework parser so mixed-case / uppercase Graph IDs are
    # accepted; a hand-rolled regex would reject valid GUIDs.
    $g = [guid]::Empty
    return [guid]::TryParse($Value, [ref]$g)
}

function ConvertTo-CaTargetEntity {
    <#
    .SYNOPSIS
        Resolve a CA condition value (user id, group id, app id, named
        location id) to a canonical EntityId + EntityType pair.
    .DESCRIPTION
        Sentinels (All, None, GuestsOrExternalUsers) and non-GUID strings
        are filtered out so they do not produce malformed edges. Each
        category routes through ConvertTo-CanonicalEntityId so the IDs
        match what the rest of the pipeline emits. Role-template IDs are
        recognised but not emitted as edges yet -- the schema does not
        yet have a Role EntityType, and collapsing them onto User would
        misclassify directory roles as users (see PR #1012 review).
    #>
    param (
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [ValidateSet('User','Group','Role','Application','NamedLocation')]
        [string] $Category
    )
    if ($script:CaSentinels -contains $Value) { return $null }
    if (-not (Test-IsGuid $Value)) { return $null }

    try {
        switch ($Category) {
            'User' {
                $c = ConvertTo-CanonicalEntityId -RawId $Value -EntityType 'User'
                return [PSCustomObject]@{ EntityId = $c.CanonicalId; EntityType = 'User'; Platform = 'Entra' }
            }
            'Application' {
                $c = ConvertTo-CanonicalEntityId -RawId $Value -EntityType 'Application'
                return [PSCustomObject]@{ EntityId = $c.CanonicalId; EntityType = 'Application'; Platform = 'Entra' }
            }
            'NamedLocation' {
                $c = ConvertTo-CanonicalEntityId -RawId $Value -EntityType 'NamedLocation'
                return [PSCustomObject]@{ EntityId = $c.CanonicalId; EntityType = 'NamedLocation'; Platform = 'Entra' }
            }
            'Group' {
                # Schema does not yet have a Group EntityType; collapse onto
                # User with an objectId: prefix so the edge still links
                # something canonical instead of being dropped. Reports
                # render the literal CanonicalId so this stays auditable.
                $lower = $Value.ToLowerInvariant()
                return [PSCustomObject]@{ EntityId = "objectId:$lower"; EntityType = 'User'; Platform = 'Entra' }
            }
            'Role' {
                # Skip role-template IDs until the schema gains a Role
                # EntityType. Collapsing onto User would misclassify
                # directory roles (e.g. Global Administrator) as user
                # principals and pollute the graph.
                return $null
            }
        }
    } catch {
        return $null
    }
    return $null
}

function New-CaPolicyEdges {
    <#
    .SYNOPSIS
        Emit AppliesTo / Excludes edges for a single CA policy projection.
    #>
    param (
        [Parameter(Mandatory)] [PSCustomObject] $Projection,
        [Parameter(Mandatory)] [string] $PolicyEntityId
    )
    $edges = [System.Collections.Generic.List[PSCustomObject]]::new()

    $includeMap = [ordered]@{
        IncludeUsers  = 'User'
        IncludeGroups = 'Group'
        IncludeRoles  = 'Role'
        IncludeApps   = 'Application'
        IncludeLocs   = 'NamedLocation'
    }
    $excludeMap = [ordered]@{
        ExcludeUsers  = 'User'
        ExcludeGroups = 'Group'
        ExcludeRoles  = 'Role'
        ExcludeApps   = 'Application'
        ExcludeLocs   = 'NamedLocation'
    }

    foreach ($field in $includeMap.Keys) {
        $cat = $includeMap[$field]
        foreach ($val in @(Get-PropertyValue -Obj $Projection -Name $field -Default @())) {
            $target = ConvertTo-CaTargetEntity -Value ([string]$val) -Category $cat
            if (-not $target) { continue }
            $edge = New-Edge -Source $PolicyEntityId -Target $target.EntityId `
                -Relation 'AppliesTo' -Platform 'Entra' `
                -DiscoveredBy 'conditional-access-graph' `
                -Confidence 'Confirmed' `
                -Properties @{ Category = $cat; PolicyState = $Projection.State }
            if ($edge) { $edges.Add($edge) | Out-Null }
        }
    }
    foreach ($field in $excludeMap.Keys) {
        $cat = $excludeMap[$field]
        foreach ($val in @(Get-PropertyValue -Obj $Projection -Name $field -Default @())) {
            $target = ConvertTo-CaTargetEntity -Value ([string]$val) -Category $cat
            if (-not $target) { continue }
            $edge = New-Edge -Source $PolicyEntityId -Target $target.EntityId `
                -Relation 'Excludes' -Platform 'Entra' `
                -DiscoveredBy 'conditional-access-graph' `
                -Confidence 'Confirmed' `
                -Properties @{ Category = $cat; PolicyState = $Projection.State }
            if ($edge) { $edges.Add($edge) | Out-Null }
        }
    }
    return @($edges)
}

function Normalize-ConditionalAccessGraph {
    <#
    .DESCRIPTION
        Returns a flat array of v2 FindingRow objects. When the caller
        passes -EdgeCollector (the orchestrator's
        $normalizerEdgeCollectorFM list), AppliesTo / Excludes edges are
        appended to it for the EntityStore drain. Test suites that want
        the edge list back without supplying a collector should pass an
        empty `[System.Collections.Generic.List[psobject]]::new()`.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult,

        [System.Collections.Generic.List[psobject]] $EdgeCollector
    )

    if (-not $ToolResult -or $ToolResult.Status -ne 'Success') {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $rows  = [System.Collections.Generic.List[PSCustomObject]]::new()

    $projections = @(Get-PropertyValue -Obj $ToolResult -Name 'Policies' -Default @())
    $rawFindings = @(Get-PropertyValue -Obj $ToolResult -Name 'Findings' -Default @())

    # FindingRows. Each finding is anchored to the policy's canonical entity
    # id so the report and the EntityStore can pivot on the policy.
    foreach ($f in $rawFindings) {
        if (-not $f) { continue }
        $policyId = [string](Get-PropertyValue -Obj $f -Name 'ResourceId' -Default '')
        if ([string]::IsNullOrWhiteSpace($policyId)) { continue }
        try {
            $canon = ConvertTo-CanonicalEntityId -RawId $policyId -EntityType 'ConditionalAccessPolicy'
        } catch {
            continue
        }

        $rawSev = [string](Get-PropertyValue -Obj $f -Name 'Severity' -Default 'Medium')
        $severity = switch -Regex ($rawSev.ToLowerInvariant()) {
            'critical'        { 'Critical' }
            'high'            { 'High' }
            'medium|moderate' { 'Medium' }
            'low'             { 'Low' }
            'info'            { 'Info' }
            default           { 'Medium' }
        }

        $detail = Remove-Credentials ([string](Get-PropertyValue -Obj $f -Name 'Detail' -Default ''))

        $row = New-FindingRow `
            -Id              ([string](Get-PropertyValue -Obj $f -Name 'Id' -Default ([guid]::NewGuid().ToString()))) `
            -Source          'conditional-access-graph' `
            -EntityId        $canon.CanonicalId `
            -EntityType      'ConditionalAccessPolicy' `
            -Platform        'Entra' `
            -Title           ([string](Get-PropertyValue -Obj $f -Name 'Title' -Default 'Conditional Access policy gap')) `
            -Compliant       $false `
            -ProvenanceRunId $runId `
            -Category        ([string](Get-PropertyValue -Obj $f -Name 'Category'    -Default 'Identity Graph')) `
            -Severity        $severity `
            -Detail          $detail `
            -Remediation     ([string](Get-PropertyValue -Obj $f -Name 'Remediation' -Default '')) `
            -ResourceId      $policyId `
            -RuleId          ([string](Get-PropertyValue -Obj $f -Name 'RuleId'      -Default '')) `
            -Pillar          ([string](Get-PropertyValue -Obj $f -Name 'Pillar'      -Default 'Identity')) `
            -Impact          ([string](Get-PropertyValue -Obj $f -Name 'Impact'      -Default 'Medium')) `
            -Effort          ([string](Get-PropertyValue -Obj $f -Name 'Effort'      -Default 'Low')) `
            -DeepLinkUrl     ([string](Get-PropertyValue -Obj $f -Name 'DeepLinkUrl' -Default '')) `
            -Confidence      'Confirmed' `
            -BaselineTags    @("ca:state:$([string](Get-PropertyValue -Obj $f -Name 'PolicyState' -Default ''))")

        if ($null -ne $row) { $rows.Add($row) | Out-Null }
    }

    # Edges. Iterate the projections and emit AppliesTo / Excludes edges
    # for every targeted user / group / app / location.
    foreach ($proj in $projections) {
        if (-not $proj) { continue }
        $policyRaw = [string](Get-PropertyValue -Obj $proj -Name 'Id' -Default '')
        if ([string]::IsNullOrWhiteSpace($policyRaw)) { continue }
        try {
            $canon = ConvertTo-CanonicalEntityId -RawId $policyRaw -EntityType 'ConditionalAccessPolicy'
        } catch {
            continue
        }
        foreach ($e in (New-CaPolicyEdges -Projection $proj -PolicyEntityId $canon.CanonicalId)) {
            if ($null -ne $EdgeCollector) { $EdgeCollector.Add($e) | Out-Null }
        }
    }

    return @($rows)
}
