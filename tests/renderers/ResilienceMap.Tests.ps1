# ResilienceMap.Tests.ps1

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'modules/shared/Renderers/ResilienceMapRenderer.ps1') -Force

    function New-TestEntity {
        param(
            [string] $EntityId,
            [string] $Region = 'westeurope',
            [string] $Zone = '1',
            [string] $Scope = 'mg-core',
            [hashtable] $RawProperties = @{}
        )
        [PSCustomObject]@{
            EntityId      = $EntityId
            EntityType    = 'AzureResource'
            Properties    = @{ Region = $Region; Zone = $Zone; Scope = $Scope }
            RawProperties = $RawProperties
        }
    }

    function New-TestEdge {
        param([string] $Source, [string] $Target, [string] $Relation)
        [PSCustomObject]@{
            Source   = $Source
            Target   = $Target
            Relation = $Relation
        }
    }
}

Describe 'ResilienceMapRenderer (#429)' {

    Context 'Edge relation styling' {
        It 'styles DependsOn as solid weighted edge' {
            $style = Resolve-ResilienceEdgeStyle -Relation 'DependsOn'
            $style.DashArray | Should -Be ''
            $style.StrokeWidth | Should -Be 2
            $style.HiddenByDefault | Should -BeFalse
        }
        It 'styles FailsOverTo as dashed double-headed edge' {
            $style = Resolve-ResilienceEdgeStyle -Relation 'FailsOverTo'
            $style.DashArray | Should -Be '6 3'
            $style.ArrowHead | Should -Be 'double'
        }
        It 'styles ReplicatedTo as dotted single-headed edge' {
            $style = Resolve-ResilienceEdgeStyle -Relation 'ReplicatedTo'
            $style.DashArray | Should -Be '2 4'
            $style.ArrowHead | Should -Be 'single'
        }
        It 'hides BackedUpBy edges until toggle' {
            $style = Resolve-ResilienceEdgeStyle -Relation 'BackedUpBy'
            $style.HiddenByDefault | Should -BeTrue
        }
        It 'styles RegionPinned and ZonePinned with tier-weighted color' {
            (Resolve-ResilienceEdgeStyle -Relation 'RegionPinned').Stroke | Should -Not -BeNullOrEmpty
            (Resolve-ResilienceEdgeStyle -Relation 'ZonePinned').Stroke | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Heatmap cells' {
        It 'colors cells red when no controls present' {
            $entities = @(New-TestEntity -EntityId 'resource:a')
            $cells = Get-ResilienceHeatmapCells -Entities $entities -Edges @()
            $cells.Count | Should -Be 1
            $cells[0].Color | Should -Be 'red'
        }
        It 'colors cells green when all 3 controls + zone-redundant' {
            $entities = @(New-TestEntity -EntityId 'resource:a')
            $edges = @(
                New-TestEdge -Source 'resource:a' -Target 'region:westeurope' -Relation 'RegionPinned'
                New-TestEdge -Source 'resource:a' -Target 'zone:westeurope-1' -Relation 'ZonePinned'
                New-TestEdge -Source 'resource:a' -Target 'vault:v1' -Relation 'BackedUpBy'
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'ReplicatedTo'
            )
            $cells = Get-ResilienceHeatmapCells -Entities $entities -Edges $edges
            $cells[0].Color | Should -Be 'green'
        }
        It 'encodes backup coverage fraction as fill density' {
            $entities = @(
                New-TestEntity -EntityId 'resource:a'
                New-TestEntity -EntityId 'resource:b'
            )
            $edges = @(
                New-TestEdge -Source 'resource:a' -Target 'vault:v1' -Relation 'BackedUpBy'
            )
            $cells = Get-ResilienceHeatmapCells -Entities $entities -Edges $edges
            $cells[0].FillDensity | Should -Be 50
        }
        It 'expands per-zone sub-grid on click at Tier 1 and Tier 2' {
            $entities = @(New-TestEntity -EntityId 'resource:a')
            $storePath = Join-Path $TestDrive 'tier12-entities.json'
            @{
                SchemaVersion = '3.1'
                Entities      = $entities
                Edges         = @()
            } | ConvertTo-Json -Depth 16 | Set-Content -Path $storePath -Encoding UTF8

            $tier1 = Invoke-ResilienceMapRender -EntityStorePath $storePath -Tier 1 -OutputPath (Join-Path $TestDrive 'tier1')
            $tier2 = Invoke-ResilienceMapRender -EntityStorePath $storePath -Tier 2 -OutputPath (Join-Path $TestDrive 'tier2')

            $tier1.Cells[0].Expandable | Should -BeTrue
            $tier2.Cells[0].Expandable | Should -BeTrue
        }
        It 'reduces to mgmt-group heatmap cells only at Tier 3' {
            $entities = @(
                New-TestEntity -EntityId 'resource:a' -Zone '1'
                New-TestEntity -EntityId 'resource:b' -Zone '2'
            )
            $edges = @(
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'DependsOn'
            )
            $storePath = Join-Path $TestDrive 'tier3-entities.json'
            @{
                SchemaVersion = '3.1'
                Entities      = $entities
                Edges         = $edges
            } | ConvertTo-Json -Depth 16 | Set-Content -Path $storePath -Encoding UTF8

            $result = Invoke-ResilienceMapRender -EntityStorePath $storePath -Tier 3 -OutputPath (Join-Path $TestDrive 'tier3')
            $result.EdgeCount | Should -Be 0
            $result.Cells[0].Scope | Should -Be 'ManagementGroup'
            $result.Cells[0].Zone | Should -Be '*'
        }
    }

    Context 'Recovery objective overlay (graceful absence, depends on #432b)' {
        It 'renders RTO/RPO badge when canonical FindingRow fields present (post-#432b)' {
            $entity = [PSCustomObject]@{
                EntityId                = 'resource:a'
                RecoveryTimeObjective   = '4h'
                RecoveryPointObjective  = '15m'
                RawProperties           = @{}
            }
            $overlay = Get-RecoveryObjectiveOverlay -Entity $entity
            $overlay.Rto | Should -Be '4h'
            $overlay.Rpo | Should -Be '15m'
        }
        It 'falls back to Entity.RawProperties when canonical field absent (pre-#432b)' {
            $entity = [PSCustomObject]@{
                EntityId      = 'resource:a'
                RawProperties = @{ RecoveryTimeObjective = '8h'; RecoveryPointObjective = '1h' }
            }
            $overlay = Get-RecoveryObjectiveOverlay -Entity $entity
            $overlay.Rto | Should -Be '8h'
            $overlay.Rpo | Should -Be '1h'
        }
        It 'returns $null and renders nothing when both canonical and raw fields absent' {
            $entity = [PSCustomObject]@{ EntityId = 'resource:a'; RawProperties = @{} }
            $overlay = Get-RecoveryObjectiveOverlay -Entity $entity
            $overlay | Should -BeNullOrEmpty
        }
        It 'never throws on missing recovery fields in any state' {
            { Get-RecoveryObjectiveOverlay -Entity ([PSCustomObject]@{ EntityId = 'resource:a' }) } | Should -Not -Throw
        }
    }

    Context 'Shared canvas budget (parity with #428, #434)' {
        It 'yields resilience edges first when over shared 2500 cap' {
            $entities = @(
                New-TestEntity -EntityId 'resource:a'
                New-TestEntity -EntityId 'resource:b'
                New-TestEntity -EntityId 'resource:c'
            )
            $edges = @(
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'DependsOn'
                New-TestEdge -Source 'resource:b' -Target 'resource:c' -Relation 'FailsOverTo'
                New-TestEdge -Source 'resource:c' -Target 'resource:a' -Relation 'ReplicatedTo'
            )
            $storePath = Join-Path $TestDrive 'budget-entities.json'
            @{
                SchemaVersion = '3.1'
                Entities      = $entities
                Edges         = $edges
            } | ConvertTo-Json -Depth 16 | Set-Content -Path $storePath -Encoding UTF8

            $result = Invoke-ResilienceMapRender -EntityStorePath $storePath -Tier 1 -OutputPath (Join-Path $TestDrive 'budget') -SharedEdgeBudget 2
            $result.EdgeCount | Should -Be 2
        }
        It 'never suppresses heatmap cells regardless of edge cap' {
            $entities = @(
                New-TestEntity -EntityId 'resource:a'
                New-TestEntity -EntityId 'resource:b'
            )
            $edges = @(
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'DependsOn'
            )
            $storePath = Join-Path $TestDrive 'edgecap-entities.json'
            @{
                SchemaVersion = '3.1'
                Entities      = $entities
                Edges         = $edges
            } | ConvertTo-Json -Depth 16 | Set-Content -Path $storePath -Encoding UTF8

            $result = Invoke-ResilienceMapRender -EntityStorePath $storePath -Tier 1 -OutputPath (Join-Path $TestDrive 'edgecap') -SharedEdgeBudget 0
            $result.EdgeCount | Should -Be 0
            $result.CellCount | Should -BeGreaterThan 0
        }
        It 'reports DroppedEdges count in render output' {
            $entities = @(
                New-TestEntity -EntityId 'resource:a'
                New-TestEntity -EntityId 'resource:b'
                New-TestEntity -EntityId 'resource:c'
            )
            $edges = @(
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'DependsOn'
                New-TestEdge -Source 'resource:b' -Target 'resource:c' -Relation 'FailsOverTo'
                New-TestEdge -Source 'resource:c' -Target 'resource:a' -Relation 'ReplicatedTo'
            )
            $storePath = Join-Path $TestDrive 'dropped-entities.json'
            @{
                SchemaVersion = '3.1'
                Entities      = $entities
                Edges         = $edges
            } | ConvertTo-Json -Depth 16 | Set-Content -Path $storePath -Encoding UTF8

            $result = Invoke-ResilienceMapRender -EntityStorePath $storePath -Tier 1 -OutputPath (Join-Path $TestDrive 'dropped') -SharedEdgeBudget 1
            $result.DroppedEdges | Should -Be 2
        }
    }

    Context 'Blast radius (60-second auditor query)' {
        It 'returns full impacted set within MaxDepth at Tier 1' {
            $edges = @(
                New-TestEdge -Source 'resource:root' -Target 'resource:a' -Relation 'DependsOn'
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'FailsOverTo'
                New-TestEdge -Source 'resource:b' -Target 'resource:c' -Relation 'ReplicatedTo'
            )
            $result = Resolve-BlastRadius -RootEntityId 'resource:root' -Edges $edges -MaxDepth 3
            ($result.EntityId) | Should -Contain 'resource:root'
            ($result.EntityId) | Should -Contain 'resource:c'
        }
        It 'returns subscription-aggregated set at Tier 2' {
            $edges = @(
                New-TestEdge -Source 'subscription:s1' -Target 'resource:a' -Relation 'DependsOn'
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'FailsOverTo'
            )
            $result = Resolve-BlastRadius -RootEntityId 'subscription:s1' -Edges $edges -MaxDepth 2
            ($result.EntityId) | Should -Contain 'subscription:s1'
            ($result.EntityId) | Should -Contain 'resource:b'
        }
        It 'returns mgmt-group-aggregated set at Tier 3' {
            $edges = @(
                New-TestEdge -Source 'mg:root' -Target 'subscription:s1' -Relation 'DependsOn'
                New-TestEdge -Source 'subscription:s1' -Target 'resource:a' -Relation 'ReplicatedTo'
            )
            $result = Resolve-BlastRadius -RootEntityId 'mg:root' -Edges $edges -MaxDepth 2
            ($result.EntityId) | Should -Contain 'mg:root'
            ($result.EntityId) | Should -Contain 'resource:a'
        }
        It 'traverses DependsOn, FailsOverTo, ReplicatedTo only' {
            $edges = @(
                New-TestEdge -Source 'resource:root' -Target 'resource:a' -Relation 'DependsOn'
                New-TestEdge -Source 'resource:a' -Target 'resource:b' -Relation 'BackedUpBy'
                New-TestEdge -Source 'resource:a' -Target 'resource:c' -Relation 'ReplicatedTo'
            )
            $result = Resolve-BlastRadius -RootEntityId 'resource:root' -Edges $edges -MaxDepth 3
            ($result.EntityId) | Should -Contain 'resource:c'
            ($result.EntityId) | Should -Not -Contain 'resource:b'
        }
    }
}
