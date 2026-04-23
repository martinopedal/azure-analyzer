#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Policy\PolicyEnforcementRenderer.ps1')
}

Describe 'Policy enforcement renderer' -Tag 'policy' {
    It 'maps compliance percentages into the expected heatmap buckets' {
        Get-ComplianceHeatmapColor -Percent 100 | Should -Be '#2e7d32'
        Get-ComplianceHeatmapColor -Percent 95 | Should -Be '#66bb6a'
        Get-ComplianceHeatmapColor -Percent 75 | Should -Be '#fdd835'
        Get-ComplianceHeatmapColor -Percent 60 | Should -Be '#fb8c00'
        Get-ComplianceHeatmapColor -Percent 20 | Should -Be '#c62828'
    }

    It 'builds Cytoscape payload with inheritance/exemption policy semantics' {
        $entities = @(
            [pscustomobject]@{ EntityId = '/providers/microsoft.management/managementgroups/root'; EntityType = 'ManagementGroup'; DisplayName = 'Root MG'; FailingAssignments = @('pa-1') },
            [pscustomobject]@{ EntityId = '00000000-0000-0000-0000-000000000001'; EntityType = 'Subscription'; DisplayName = 'Prod Sub' },
            [pscustomobject]@{ EntityId = 'exemption:1'; EntityType = 'PolicyExemption'; DisplayName = 'Exemption #1'; Reason = 'Legacy workload'; ExpiresOn = '2027-01-01' }
        )
        $edges = @(
            [pscustomobject]@{ Source = '00000000-0000-0000-0000-000000000001'; Target = '/providers/microsoft.management/managementgroups/root'; Relation = 'InheritsFrom' },
            [pscustomobject]@{ Source = 'exemption:1'; Target = 'policyassignment:demo'; Relation = 'ExemptedFrom' }
        )
        $compliance = @{
            '/providers/microsoft.management/managementgroups/root' = 72
            '00000000-0000-0000-0000-000000000001' = 39
            'exemption:1' = 100
        }

        $graph = Invoke-PolicyEnforcementRender -Entities $entities -Edges $edges -ComplianceState $compliance -Tier 1
        @($graph.elements.nodes).Count | Should -Be 3
        @($graph.elements.edges).Count | Should -Be 2

        $inheritEdge = $graph.elements.edges | Where-Object { $_.data.relation -eq 'InheritsFrom' } | Select-Object -First 1
        $inheritEdge.data.style.lineStyle | Should -Be 'dashed'

        $exemptionNode = $graph.elements.nodes | Where-Object { $_.data.entityType -eq 'PolicyExemption' } | Select-Object -First 1
        $exemptionNode.data.tooltip | Should -Match 'Legacy workload'

        $mgNode = $graph.elements.nodes | Where-Object { $_.data.id -eq '/providers/microsoft.management/managementgroups/root' } | Select-Object -First 1
        @($mgNode.data.failingAssignments) | Should -Contain 'pa-1'
    }
}
