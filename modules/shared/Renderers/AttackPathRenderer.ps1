# AttackPathRenderer.ps1
#
# Track A (attack-path visualizer) renderer module — SCAFFOLD ONLY.
#
# Function bodies are intentionally empty. Implementation is blocked on
# Foundation PR #435, which lands:
#   * the six new EdgeRelations enum values in modules/shared/Schema.ps1
#   * the optional -EdgeCollector normalizer parameter contract
#   * cytoscape.js + cytoscape-dagre vendor files under assets/vendor/
#
# See docs/design/attack-path.md for the full contract.
# Issue: #428. Epic: #427.

Set-StrictMode -Version Latest

function Get-AttackPathSeverityRank {
    param([string] $Severity)

    switch (($Severity ?? '').ToLowerInvariant()) {
        'critical' { return 5 }
        'high' { return 4 }
        'medium' { return 3 }
        'low' { return 2 }
        'info' { return 1 }
        default { return 0 }
    }
}

function Get-AttackPathSeverityLabel {
    param([int] $Rank)

    switch ($Rank) {
        5 { return 'Critical' }
        4 { return 'High' }
        3 { return 'Medium' }
        2 { return 'Low' }
        1 { return 'Info' }
        default { return 'Info' }
    }
}

function Remove-AttackPathNullProperties {
    param([object] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $clean = @{}
        foreach ($key in @($Value.Keys)) {
            $child = Remove-AttackPathNullProperties -Value $Value[$key]
            if ($null -eq $child) { continue }
            if ($child -is [string] -and [string]::IsNullOrWhiteSpace($child)) { continue }
            $clean[$key] = $child
        }
        return $clean
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($Value)) {
            $child = Remove-AttackPathNullProperties -Value $item
            if ($null -eq $child) { continue }
            $items.Add($child) | Out-Null
        }
        return @($items)
    }

    $props = @($Value.PSObject.Properties)
    if ($props.Count -eq 0) { return $Value }

    $obj = [ordered]@{}
    foreach ($prop in $props) {
        $child = Remove-AttackPathNullProperties -Value $prop.Value
        if ($null -eq $child) { continue }
        if ($child -is [string] -and [string]::IsNullOrWhiteSpace($child)) { continue }
        $obj[$prop.Name] = $child
    }
    return $obj
}

function New-AttackPathModel {
    <#
    .SYNOPSIS
        Build the Cytoscape elements payload for the attack-path canvas.
    .DESCRIPTION
        Reads the v3 entity store + findings store and emits a hashtable shaped
        for the #atkPathModel JSON island. Honours the shared per-canvas edge
        budget (Tier 1 default 2500). Returns nodes/edges plus a budget block
        and a truncated flag.

        Body intentionally empty — waits on Foundation #435.
    .PARAMETER Entities
        Entity collection from EntityStore (v3).
    .PARAMETER Findings
        Finding rows used for severity weighting and click-to-pivot mapping.
    .PARAMETER Tier
        Rendering tier (1-4). Drives sampling and hydration strategy.
    .PARAMETER EdgeBudget
        Shared per-canvas edge cap. Default 2500 for Tier 1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Entities,
        [Parameter(Mandatory)] [object[]] $Findings,
        [ValidateRange(1, 4)] [int] $Tier = 1,
        [ValidateRange(1, 100000)] [int] $EdgeBudget = 2500
    )
    $trackARelations = @('TriggeredBy', 'AuthenticatesAs', 'DeploysTo', 'UsesSecret', 'HasFederatedCredential', 'Declares')

    $entityMap = [ordered]@{}
    $candidateEdges = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Entities)) {
        if ($null -eq $item) { continue }

        if ($item.PSObject.Properties['Entities']) {
            foreach ($nestedEntity in @($item.Entities)) {
                if ($nestedEntity -and $nestedEntity.PSObject.Properties['EntityId']) {
                    $id = ([string]$nestedEntity.EntityId).ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($id) -and -not $entityMap.Contains($id)) {
                        $entityMap[$id] = $nestedEntity
                    }
                }
            }
        }

        if ($item.PSObject.Properties['Edges']) {
            foreach ($nestedEdge in @($item.Edges)) {
                if ($nestedEdge) { $candidateEdges.Add($nestedEdge) | Out-Null }
            }
        }

        if ($item.PSObject.Properties['EntityId']) {
            $id = ([string]$item.EntityId).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($id) -and -not $entityMap.Contains($id)) {
                $entityMap[$id] = $item
            }
        }

        if ($item.PSObject.Properties['Relation'] -and $item.PSObject.Properties['Source'] -and $item.PSObject.Properties['Target']) {
            $candidateEdges.Add($item) | Out-Null
        }
    }

    $findingMap = @{}
    $severityByEntity = @{}
    foreach ($finding in @($Findings)) {
        if ($null -eq $finding) { continue }
        $entityIds = [System.Collections.Generic.List[string]]::new()

        if ($finding.PSObject.Properties['EntityId'] -and $finding.EntityId) {
            $entityIds.Add(([string]$finding.EntityId).ToLowerInvariant()) | Out-Null
        }
        if ($finding.PSObject.Properties['Entity'] -and $finding.Entity) {
            $entityIds.Add(([string]$finding.Entity).ToLowerInvariant()) | Out-Null
        }
        if ($finding.PSObject.Properties['EntityRefs']) {
            foreach ($entityRef in @($finding.EntityRefs)) {
                $ref = [string]$entityRef
                if ([string]::IsNullOrWhiteSpace($ref)) { continue }
                if ($ref -match '^https?://') { continue }
                $entityIds.Add($ref.Trim().ToLowerInvariant()) | Out-Null
            }
        }

        $severity = if ($finding.PSObject.Properties['Severity']) { [string]$finding.Severity } else { '' }
        $rank = Get-AttackPathSeverityRank -Severity $severity

        foreach ($entityId in @($entityIds | Select-Object -Unique)) {
            if (-not $findingMap.ContainsKey($entityId)) {
                $findingMap[$entityId] = [System.Collections.Generic.List[object]]::new()
            }
            $findingMap[$entityId].Add($finding) | Out-Null
            if (-not $severityByEntity.ContainsKey($entityId) -or $rank -gt $severityByEntity[$entityId]) {
                $severityByEntity[$entityId] = $rank
            }
        }
    }

    $rankedEdges = [System.Collections.Generic.List[object]]::new()
    foreach ($edge in @($candidateEdges)) {
        $relation = if ($edge.PSObject.Properties['Relation']) { [string]$edge.Relation } else { '' }
        if ($relation -notin $trackARelations) { continue }
        $source = if ($edge.PSObject.Properties['Source']) { ([string]$edge.Source).ToLowerInvariant() } else { '' }
        $target = if ($edge.PSObject.Properties['Target']) { ([string]$edge.Target).ToLowerInvariant() } else { '' }
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) { continue }
        $edgeRank = [Math]::Max(
            $(if ($severityByEntity.ContainsKey($source)) { [int]$severityByEntity[$source] } else { 0 }),
            $(if ($severityByEntity.ContainsKey($target)) { [int]$severityByEntity[$target] } else { 0 })
        )
        $edgeId = if ($edge.PSObject.Properties['EdgeId'] -and $edge.EdgeId) {
            [string]$edge.EdgeId
        } else {
            "edge:$source|$relation|$target"
        }

        if (-not $entityMap.Contains($source)) {
            $entityMap[$source] = [pscustomobject]@{ EntityId = $source; EntityType = 'Unknown'; DisplayName = $source; Platform = '' }
        }
        if (-not $entityMap.Contains($target)) {
            $entityMap[$target] = [pscustomobject]@{ EntityId = $target; EntityType = 'Unknown'; DisplayName = $target; Platform = '' }
        }

        $rankedEdges.Add([pscustomobject]@{
                Edge = $edge
                EdgeId = $edgeId
                Source = $source
                Target = $target
                Relation = $relation
                Rank = $edgeRank
            }) | Out-Null
    }

    $requestedEdges = @($rankedEdges).Count
    $selectedEdges = @()
    if ($Tier -eq 1) {
        $selectedEdges = @($rankedEdges | Sort-Object -Property @{ Expression = 'Rank'; Descending = $true }, EdgeId | Select-Object -First $EdgeBudget)
    } elseif ($Tier -eq 2) {
        $seedNodes = @($severityByEntity.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 200 | ForEach-Object { $_.Key })
        $selectedEdges = @($rankedEdges | Where-Object { $_.Source -in $seedNodes -or $_.Target -in $seedNodes } | Sort-Object -Property @{ Expression = 'Rank'; Descending = $true }, EdgeId | Select-Object -First $EdgeBudget)
    } else {
        $selectedEdges = @()
    }

    $nodesUsed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($selected in @($selectedEdges)) {
        $nodesUsed.Add($selected.Source) | Out-Null
        $nodesUsed.Add($selected.Target) | Out-Null
    }
    if (@($selectedEdges).Count -eq 0) {
        foreach ($candidate in @($severityByEntity.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 200)) {
            $nodesUsed.Add($candidate.Key) | Out-Null
        }
    }

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($nodeId in @($nodesUsed)) {
        if (-not $entityMap.Contains($nodeId)) { continue }
        $entity = $entityMap[$nodeId]
        $entityType = if ($entity.PSObject.Properties['EntityType'] -and $entity.EntityType) { [string]$entity.EntityType } else { 'Unknown' }
        $displayName = if ($entity.PSObject.Properties['DisplayName'] -and $entity.DisplayName) { [string]$entity.DisplayName } else { $nodeId }
        $platform = if ($entity.PSObject.Properties['Platform'] -and $entity.Platform) { [string]$entity.Platform } else { '' }
        $rank = if ($severityByEntity.ContainsKey($nodeId)) { [int]$severityByEntity[$nodeId] } else { 0 }

        $nodes.Add([ordered]@{
                data = [ordered]@{
                    id = $nodeId
                    type = $entityType
                    label = $displayName
                    platform = $platform
                    severity = (Get-AttackPathSeverityLabel -Rank $rank)
                    findingCount = $(if ($findingMap.ContainsKey($nodeId)) { @($findingMap[$nodeId]).Count } else { 0 })
                }
            }) | Out-Null
    }

    $edges = [System.Collections.Generic.List[object]]::new()
    foreach ($selected in @($selectedEdges)) {
        $edges.Add([ordered]@{
                data = [ordered]@{
                    id = $selected.EdgeId
                    source = $selected.Source
                    target = $selected.Target
                    relation = $selected.Relation
                    severity = (Get-AttackPathSeverityLabel -Rank ([int]$selected.Rank))
                    layer = 'attack'
                }
            }) | Out-Null
    }

    $hydration = switch ($Tier) {
        1 { [ordered]@{ mode = 'inline'; source = 'atkPathModel' } }
        2 { [ordered]@{ mode = 'sqlite-wasm'; strategy = 'top-n-seed'; seedNodeCap = 200; expand = 'one-hop' } }
        3 { [ordered]@{ mode = 'worker-tiles'; strategy = 'viewport-stream'; fetch = '/graph/attack-path/tiles' } }
        default { [ordered]@{ mode = 'pode-api'; endpoint = '/api/graph/attack-paths'; strategy = 'recursive-cte' } }
    }

    $pivot = @{}
    foreach ($key in @($findingMap.Keys)) {
        $pivot[$key] = @($findingMap[$key] | ForEach-Object {
                [ordered]@{
                    id = $(if ($_.PSObject.Properties['Id']) { [string]$_.Id } else { '' })
                    title = $(if ($_.PSObject.Properties['Title']) { [string]$_.Title } else { '' })
                    severity = $(if ($_.PSObject.Properties['Severity']) { [string]$_.Severity } else { '' })
                    source = $(if ($_.PSObject.Properties['Source']) { [string]$_.Source } else { '' })
                }
            })
    }

    return [ordered]@{
        schemaVersion = '3.0'
        tier = $Tier
        truncated = ($requestedEdges -gt @($selectedEdges).Count)
        budget = [ordered]@{
            edgeCap = $EdgeBudget
            requested = $requestedEdges
            edgesUsed = @($selectedEdges).Count
        }
        nodes = @($nodes)
        edges = @($edges)
        hydration = $hydration
        findingMap = $pivot
    }
}

function ConvertTo-AttackPathDataIsland {
    <#
    .SYNOPSIS
        Serialize an attack-path model to the HTML data-island JSON string.
    .DESCRIPTION
        Wraps the model produced by New-AttackPathModel in the schema envelope
        consumed by the in-browser cytoscape renderer.

        Body intentionally empty — waits on Foundation #435.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Model
    )
    $cleanModel = Remove-AttackPathNullProperties -Value $Model
    return ($cleanModel | ConvertTo-Json -Depth 16 -Compress)
}

function Get-AttackPathBudgetReport {
    <#
    .SYNOPSIS
        Report requested vs allocated edges for the shared canvas budget.
    .DESCRIPTION
        Returns a hashtable with Requested / Allocated / Truncated, used by the
        canvas controller to coordinate with Track B (#430) and Track C (#434).

        Body intentionally empty — waits on Foundation #435.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Model
    )
    $budget = if ($Model.ContainsKey('budget') -and $Model.budget) { $Model.budget } else { @{} }
    $requested = if ($budget.requested -is [int]) { [int]$budget.requested } elseif ($budget.requested) { [int]$budget.requested } else { @($Model.edges).Count }
    $allocated = if ($budget.edgesUsed -is [int]) { [int]$budget.edgesUsed } elseif ($budget.edgesUsed) { [int]$budget.edgesUsed } else { @($Model.edges).Count }
    $edgeCap = if ($budget.edgeCap -is [int]) { [int]$budget.edgeCap } elseif ($budget.edgeCap) { [int]$budget.edgeCap } else { $allocated }
    $truncated = if ($Model.ContainsKey('truncated')) { [bool]$Model.truncated } else { ($requested -gt $allocated) }

    return [ordered]@{
        Requested = $requested
        Allocated = $allocated
        EdgeCap = $edgeCap
        Truncated = $truncated
    }
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function New-AttackPathModel, ConvertTo-AttackPathDataIsland, Get-AttackPathBudgetReport -ErrorAction SilentlyContinue
}
