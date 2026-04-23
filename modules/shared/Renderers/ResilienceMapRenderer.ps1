# ResilienceMapRenderer.ps1
#
# Track B (#429) scaffold. Implementation held until Foundation #435 lands.
# Per Round 3 reconciliation on #427 (AUTHORITATIVE):
#   - #435 lands 16 EdgeRelations total; this renderer consumes 6:
#     DependsOn, RegionPinned, ZonePinned, BackedUpBy, FailsOverTo, ReplicatedTo.
#   - #435 does NOT add named FindingRow fields. RTO/RPO/Remediation/DocsUrl are
#     deferred to #432b. This renderer must degrade gracefully when those fields
#     are absent (silent skip, no throw, no layout shift).
#   - Hot files (Schema.ps1, Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1,
#     tool-manifest.json) are owned by #435 in Phase 0; do not edit here.
#
# See docs/design/resilience-map.md for the full design.
#
# This file intentionally contains SIGNATURES ONLY. Bodies throw NotImplemented
# so any accidental call surfaces immediately rather than silently returning.

Set-StrictMode -Version Latest

function Test-ObjectProperty {
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string[]] $Names
    )
    foreach ($name in $Names) {
        if (Test-ObjectProperty -Object $Object -Name $name) {
            $value = if ($Object -is [System.Collections.IDictionary]) { $Object[$name] } else { $Object.$name }
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }
    return $null
}

function Get-EntityResilienceMetadata {
    param([Parameter(Mandatory)] [object] $Entity)

    $properties = if (Test-ObjectProperty -Object $Entity -Name 'Properties') { $Entity.Properties } else { $null }
    $rawProperties = if (Test-ObjectProperty -Object $Entity -Name 'RawProperties') { $Entity.RawProperties } else { $null }

    $region = Get-ObjectValue -Object $Entity -Names @('Region', 'Location')
    if (-not $region) { $region = Get-ObjectValue -Object $properties -Names @('Region', 'Location') }
    if (-not $region) { $region = Get-ObjectValue -Object $rawProperties -Names @('Region', 'Location') }
    if (-not $region) { $region = 'global' }

    $zone = Get-ObjectValue -Object $Entity -Names @('Zone', 'AvailabilityZone')
    if (-not $zone) { $zone = Get-ObjectValue -Object $properties -Names @('Zone', 'AvailabilityZone') }
    if (-not $zone) { $zone = Get-ObjectValue -Object $rawProperties -Names @('Zone', 'AvailabilityZone') }
    if (-not $zone) { $zone = 'all' }

    $scope = Get-ObjectValue -Object $Entity -Names @('Scope', 'ManagementGroup')
    if (-not $scope) { $scope = Get-ObjectValue -Object $properties -Names @('Scope', 'ManagementGroup') }
    if (-not $scope) { $scope = Get-ObjectValue -Object $rawProperties -Names @('Scope', 'ManagementGroup') }
    if (-not $scope) { $scope = 'ManagementGroup' }

    return [PSCustomObject]@{
        Region = [string]$region
        Zone   = [string]$zone
        Scope  = [string]$scope
    }
}

function Invoke-ResilienceMapRender {
    <#
    .SYNOPSIS
        Render the resilience map for a given entity store and viewer tier.
    .PARAMETER EntityStorePath
        Path to entities.json produced by the orchestrator.
    .PARAMETER Tier
        Viewer tier (1, 2, or 3). Drives edge-cap and collapse behavior.
        See docs/design/resilience-map.md section 3.4.
    .PARAMETER OutputPath
        Destination directory for the rendered HTML fragment + JSON sidecar.
    .PARAMETER SharedEdgeBudget
        Remaining edge budget after attack-path (#428) and policy (#434) have
        consumed their share. Defaults to 2500.
    .OUTPUTS
        PSCustomObject with Path, EdgeCount, CellCount, DroppedEdges.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityStorePath,
        [Parameter(Mandatory)] [ValidateSet(1, 2, 3)] [int] $Tier,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter()] [int] $SharedEdgeBudget = 2500
    )
    $json = Get-Content -Path $EntityStorePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64

    if ($json -is [System.Collections.IEnumerable] -and -not ($json -is [string])) {
        $entities = @($json)
        $edges = @()
    } else {
        $entities = if (Test-ObjectProperty -Object $json -Name 'Entities') { @($json.Entities) } else { @() }
        $edges = if (Test-ObjectProperty -Object $json -Name 'Edges') { @($json.Edges) } else { @() }
    }

    $resilienceRelations = @('DependsOn', 'RegionPinned', 'ZonePinned', 'BackedUpBy', 'FailsOverTo', 'ReplicatedTo')
    $resilienceEdges = @($edges | Where-Object { $_.Relation -in $resilienceRelations })
    $cells = @(Get-ResilienceHeatmapCells -Entities $entities -Edges $resilienceEdges)

    if ($Tier -eq 3) {
        $resilienceEdges = @()
        $cells = @(
            $cells |
                Group-Object -Property Region |
                ForEach-Object {
                    $groupCells = @($_.Group)
                    [PSCustomObject]@{
                        Region       = $_.Name
                        Zone         = '*'
                        Scope        = 'ManagementGroup'
                        Score        = [Math]::Round((($groupCells | Measure-Object -Property Score -Average).Average), 2)
                        Color        = if (($groupCells.Color -contains 'red')) { 'red' } elseif (($groupCells.Color -contains 'orange')) { 'orange' } elseif (($groupCells.Color -contains 'yellow')) { 'yellow' } else { 'green' }
                        FillDensity  = [Math]::Round((($groupCells | Measure-Object -Property FillDensity -Average).Average), 2)
                        Expandable   = $false
                        BackupRatio  = [Math]::Round((($groupCells | Measure-Object -Property BackupRatio -Average).Average), 4)
                        ZoneExpanded = $false
                    }
                }
        )
    } elseif ($Tier -in @(1, 2)) {
        foreach ($cell in $cells) {
            $cell.Expandable = $true
            $cell.ZoneExpanded = $false
        }
    }

    $budget = [Math]::Max(0, $SharedEdgeBudget)
    $keptEdges = @($resilienceEdges | Select-Object -First $budget)
    $droppedEdges = [Math]::Max(0, $resilienceEdges.Count - $keptEdges.Count)

    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    $jsonPath = Join-Path $OutputPath 'resilience-map.json'
    $htmlPath = Join-Path $OutputPath 'resilience-map.html'

    $payload = [ordered]@{
        Tier         = $Tier
        EdgeCount    = $keptEdges.Count
        CellCount    = $cells.Count
        DroppedEdges = $droppedEdges
        Edges        = $keptEdges
        Cells        = $cells
    }
    $payload | ConvertTo-Json -Depth 64 | Set-Content -Path $jsonPath -Encoding UTF8
    "<div id='resilience-map' data-tier='$Tier' data-edge-count='$($keptEdges.Count)' data-cell-count='$($cells.Count)'></div>" | Set-Content -Path $htmlPath -Encoding UTF8

    return [PSCustomObject]@{
        Path         = $jsonPath
        HtmlPath     = $htmlPath
        EdgeCount    = $keptEdges.Count
        CellCount    = $cells.Count
        DroppedEdges = $droppedEdges
        Cells        = $cells
        Edges        = $keptEdges
    }
}

function Get-ResilienceHeatmapCells {
    <#
    .SYNOPSIS
        Build the per-region/zone heatmap cell matrix from entity store.
    .PARAMETER Entities
        Parsed entities.json (array of v3 entities).
    .PARAMETER Edges
        Edge collection filtered to resilience relations only.
    .OUTPUTS
        Array of cell descriptors: { Region, Zone, Scope, Score, Color, FillDensity }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Entities,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Edges
    )
    $edgeBySource = @{}
    foreach ($edge in @($Edges)) {
        if (-not (Test-ObjectProperty -Object $edge -Name 'Source')) { continue }
        $source = [string]$edge.Source
        if (-not $edgeBySource.ContainsKey($source)) {
            $edgeBySource[$source] = @()
        }
        $edgeBySource[$source] += $edge
    }

    $rows = foreach ($entity in @($Entities)) {
        if (-not (Test-ObjectProperty -Object $entity -Name 'EntityId')) { continue }

        $entityId = [string]$entity.EntityId
        $meta = Get-EntityResilienceMetadata -Entity $entity
        $entityEdges = if ($edgeBySource.ContainsKey($entityId)) { @($edgeBySource[$entityId]) } else { @() }

        $hasPinned = ($entityEdges | Where-Object { $_.Relation -in @('RegionPinned', 'ZonePinned') } | Measure-Object).Count -gt 0
        $hasBackup = ($entityEdges | Where-Object { $_.Relation -eq 'BackedUpBy' } | Measure-Object).Count -gt 0
        $hasReplica = ($entityEdges | Where-Object { $_.Relation -in @('FailsOverTo', 'ReplicatedTo') } | Measure-Object).Count -gt 0
        $zoneRedundant = ($entityEdges | Where-Object { $_.Relation -eq 'ZonePinned' } | Measure-Object).Count -gt 0

        $scoreControls = [int]$hasPinned + [int]$hasBackup + [int]$hasReplica
        [PSCustomObject]@{
            Region        = $meta.Region
            Zone          = $meta.Zone
            Scope         = $meta.Scope
            ScoreControls = $scoreControls
            HasBackup     = $hasBackup
            ZoneRedundant = $zoneRedundant
        }
    }

    $cells = foreach ($group in ($rows | Group-Object -Property Region, Zone, Scope)) {
        $items = @($group.Group)
        if ($items.Count -eq 0) { continue }

        $avgControls = ($items | Measure-Object -Property ScoreControls -Average).Average
        $backupCount = @($items | Where-Object { $_.HasBackup }).Count
        $nonRedundantCount = @($items | Where-Object { -not $_.ZoneRedundant }).Count
        $backupRatio = $backupCount / [double]$items.Count
        $allZoneRedundant = ($nonRedundantCount -eq 0)

        $color = if ($avgControls -lt 0.5) {
            'red'
        } elseif ($avgControls -lt 1.5) {
            'orange'
        } elseif ($avgControls -lt 2.5) {
            'yellow'
        } elseif ($allZoneRedundant) {
            'green'
        } else {
            'yellow'
        }

        [PSCustomObject]@{
            Region       = $items[0].Region
            Zone         = $items[0].Zone
            Scope        = $items[0].Scope
            Score        = [Math]::Round(($avgControls / 3.0) * 100.0, 2)
            Color        = $color
            FillDensity  = [Math]::Round($backupRatio * 100.0, 2)
            BackupRatio  = [Math]::Round($backupRatio, 4)
            Expandable   = $true
            ZoneExpanded = $false
        }
    }

    return @($cells)
}

function Resolve-ResilienceEdgeStyle {
    <#
    .SYNOPSIS
        Return SVG/HTML style descriptor for a resilience edge relation.
    .PARAMETER Relation
        One of: DependsOn, RegionPinned, ZonePinned, BackedUpBy, FailsOverTo, ReplicatedTo.
    .OUTPUTS
        Hashtable with Stroke, DashArray, ArrowHead, HiddenByDefault.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DependsOn', 'RegionPinned', 'ZonePinned', 'BackedUpBy', 'FailsOverTo', 'ReplicatedTo')]
        [string] $Relation
    )
    $styles = @{
        DependsOn = @{
            Stroke          = '#64748b'
            StrokeWidth     = 2
            DashArray       = ''
            ArrowHead       = 'single'
            HiddenByDefault = $false
        }
        RegionPinned = @{
            Stroke          = '#2563eb'
            StrokeWidth     = 2
            DashArray       = '1 0'
            ArrowHead       = 'single'
            HiddenByDefault = $false
        }
        ZonePinned = @{
            Stroke          = '#7c3aed'
            StrokeWidth     = 2
            DashArray       = '1 0'
            ArrowHead       = 'single'
            HiddenByDefault = $false
        }
        BackedUpBy = @{
            Stroke          = '#0891b2'
            StrokeWidth     = 1
            DashArray       = '3 3'
            ArrowHead       = 'single'
            HiddenByDefault = $true
        }
        FailsOverTo = @{
            Stroke          = '#0ea5e9'
            StrokeWidth     = 2
            DashArray       = '6 3'
            ArrowHead       = 'double'
            HiddenByDefault = $false
        }
        ReplicatedTo = @{
            Stroke          = '#14b8a6'
            StrokeWidth     = 2
            DashArray       = '2 4'
            ArrowHead       = 'single'
            HiddenByDefault = $false
        }
    }
    return $styles[$Relation]
}

function Get-RecoveryObjectiveOverlay {
    <#
    .SYNOPSIS
        Build RTO/RPO tooltip overlay for a resource entity. Returns $null when
        recovery objectives are absent (graceful absence per design 3.3).
    .DESCRIPTION
        Depends on #432b for any canonical FindingRow field carrying RTO/RPO.
        Until #432b lands, this function reads opportunistically from
        Entity.RawProperties and returns $null on absence. When #432b adds
        canonical fields, prefer the canonical field, then RawProperties, then
        silent absence. Never throws on missing fields.
    .PARAMETER Entity
        Single v3 entity object.
    .OUTPUTS
        Hashtable { Rto, Rpo, BadgeColor } or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entity
    )
    try {
        $properties = if (Test-ObjectProperty -Object $Entity -Name 'Properties') { $Entity.Properties } else { $null }
        $rawProperties = if (Test-ObjectProperty -Object $Entity -Name 'RawProperties') { $Entity.RawProperties } else { $null }

        $rto = Get-ObjectValue -Object $Entity -Names @('RecoveryTimeObjective', 'RTO')
        if (-not $rto) { $rto = Get-ObjectValue -Object $properties -Names @('RecoveryTimeObjective', 'RTO') }
        if (-not $rto) { $rto = Get-ObjectValue -Object $rawProperties -Names @('RecoveryTimeObjective', 'RTO') }

        $rpo = Get-ObjectValue -Object $Entity -Names @('RecoveryPointObjective', 'RPO')
        if (-not $rpo) { $rpo = Get-ObjectValue -Object $properties -Names @('RecoveryPointObjective', 'RPO') }
        if (-not $rpo) { $rpo = Get-ObjectValue -Object $rawProperties -Names @('RecoveryPointObjective', 'RPO') }

        if (-not $rto -and -not $rpo) {
            return $null
        }

        return @{
            Rto        = $rto
            Rpo        = $rpo
            BadgeColor = if ($rto -and $rpo) { 'blue' } elseif ($rto) { 'purple' } else { 'teal' }
        }
    } catch {
        return $null
    }
}

function Resolve-BlastRadius {
    <#
    .SYNOPSIS
        Traverse DependsOn / FailsOverTo / ReplicatedTo edges from a root entity
        and return the impacted entity set. Drives the 60-second auditor query
        in design section 1.
    .PARAMETER RootEntityId
        Canonical entity id.
    .PARAMETER Edges
        Edge collection.
    .PARAMETER MaxDepth
        Defaults to 5 (matches viewer tier 1 default).
    .OUTPUTS
        Array of impacted entity ids with Distance and EdgePath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RootEntityId,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Edges,
        [Parameter()] [int] $MaxDepth = 5
    )
    $allowed = @('DependsOn', 'FailsOverTo', 'ReplicatedTo')
    $adjacency = @{}
    foreach ($edge in @($Edges)) {
        if (-not (Test-ObjectProperty -Object $edge -Name 'Relation')) { continue }
        if ($edge.Relation -notin $allowed) { continue }
        if (-not (Test-ObjectProperty -Object $edge -Name 'Source')) { continue }
        if (-not (Test-ObjectProperty -Object $edge -Name 'Target')) { continue }

        $source = [string]$edge.Source
        if (-not $adjacency.ContainsKey($source)) {
            $adjacency[$source] = @()
        }
        $adjacency[$source] += $edge
    }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $visited = @{}
    $results = @()

    $queue.Enqueue([PSCustomObject]@{
            EntityId = $RootEntityId
            Distance = 0
            EdgePath = @()
        })
    $visited[$RootEntityId] = $true

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $results += [PSCustomObject]@{
            EntityId = $current.EntityId
            Distance = $current.Distance
            EdgePath = @($current.EdgePath)
        }

        if ($current.Distance -ge $MaxDepth) { continue }
        if (-not $adjacency.ContainsKey($current.EntityId)) { continue }

        foreach ($edge in @($adjacency[$current.EntityId])) {
            $target = [string]$edge.Target
            if ($visited.ContainsKey($target)) { continue }

            $visited[$target] = $true
            $queue.Enqueue([PSCustomObject]@{
                    EntityId = $target
                    Distance = $current.Distance + 1
                    EdgePath = @($current.EdgePath + @([PSCustomObject]@{
                                Source   = $edge.Source
                                Target   = $edge.Target
                                Relation = $edge.Relation
                            }))
                })
        }
    }

    return $results | Sort-Object -Property Distance, EntityId
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function `
        Invoke-ResilienceMapRender, `
        Get-ResilienceHeatmapCells, `
        Resolve-ResilienceEdgeStyle, `
        Get-RecoveryObjectiveOverlay, `
        Resolve-BlastRadius
}
