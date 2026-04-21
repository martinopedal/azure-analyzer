#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Normalize-AksKarpenterCost' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-AksKarpenterCost.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'aks-karpenter-cost' 'wrapper-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when status is not successful' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $rows.Count | Should -Be 0
    }

    It 'normalizes every fixture finding through New-FindingRow' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult $script:Fixture)
        $rows.Count | Should -Be 5
        foreach ($row in $rows) {
            $row.Source   | Should -Be 'aks-karpenter-cost'
            $row.Category | Should -Be 'Cost'
            $row.Platform | Should -Be 'Azure'
            $row.RuleId   | Should -Not -BeNullOrEmpty
        }
    }

    It 'maps EntityType per RuleId family' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.RuleId -eq 'aks.node-cost-rollup' }).EntityType         | Should -Be 'AzureResource'
        ($rows | Where-Object { $_.RuleId -eq 'aks.idle-node' }).EntityType                | Should -Be 'AzureResource'
        ($rows | Where-Object { $_.RuleId -eq 'karpenter.consolidation-disabled' }).EntityType | Should -Be 'KarpenterProvisioner'
        ($rows | Where-Object { $_.RuleId -eq 'karpenter.no-node-limit' }).EntityType      | Should -Be 'KarpenterProvisioner'
        ($rows | Where-Object { $_.RuleId -eq 'karpenter.over-provisioned' }).EntityType   | Should -Be 'KarpenterProvisioner'
    }

    It 'preserves the severity ladder per RuleId' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.RuleId -eq 'aks.node-cost-rollup' }).Severity         | Should -Be 'Info'
        ($rows | Where-Object { $_.RuleId -eq 'aks.idle-node' }).Severity                | Should -Be 'Medium'
        ($rows | Where-Object { $_.RuleId -eq 'karpenter.consolidation-disabled' }).Severity | Should -Be 'Medium'
        ($rows | Where-Object { $_.RuleId -eq 'karpenter.no-node-limit' }).Severity      | Should -Be 'High'
        ($rows | Where-Object { $_.RuleId -eq 'karpenter.over-provisioned' }).Severity   | Should -Be 'Medium'
    }

    It 'produces canonical lowercase entity IDs and extracts cluster scope fields' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.EntityId       | Should -Be $row.EntityId.ToLowerInvariant()
            $row.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $row.ResourceGroup  | Should -Be 'rg-aks'
        }
    }

    It 'KarpenterProvisioner canonical ID embeds the provisioner name' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult $script:Fixture)
        $karp = @($rows | Where-Object { $_.EntityType -eq 'KarpenterProvisioner' })
        $karp.Count | Should -BeGreaterThan 0
        foreach ($row in $karp) {
            $row.EntityId | Should -Match '/karpenter/provisioners/default$'
        }
    }

    It 'preserves cost-relevant extras (NodeHours, ObservedPercent, ProvisionerName, RbacTier)' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult $script:Fixture)
        $cost = $rows | Where-Object { $_.RuleId -eq 'aks.node-cost-rollup' } | Select-Object -First 1
        $cost.NodeHours    | Should -Be 840.0
        $cost.NodeCount    | Should -Be 5
        $cost.RbacTier     | Should -Be 'ClusterUser'

        $idle = $rows | Where-Object { $_.RuleId -eq 'aks.idle-node' } | Select-Object -First 1
        $idle.NodeName        | Should -Be 'aks-node-1'
        $idle.ObservedPercent | Should -Be 4.5
    }

    It 'maps Schema 2.2 cost ETL fields to New-FindingRow' {
        $rows = @(Normalize-AksKarpenterCost -ToolResult $script:Fixture)
        $cost = $rows | Where-Object { $_.RuleId -eq 'aks.node-cost-rollup' } | Select-Object -First 1
        $cost.Pillar | Should -Be 'Cost Optimization'
        $cost.Impact | Should -Be 'High'
        $cost.Effort | Should -Be 'Low'
        $cost.ScoreDelta | Should -Be 840.0
        $cost.ToolVersion | Should -Be 'kubectl=v1.31.0; karpenter=v1beta1'
        @($cost.BaselineTags) | Should -Contain 'Karpenter-NodeHours'
        @($cost.BaselineTags) | Should -Contain 'RBAC-ClusterAdmin'
        @($cost.EntityRefs) | Should -Contain '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod'

        $consolidation = $rows | Where-Object { $_.RuleId -eq 'karpenter.consolidation-disabled' } | Select-Object -First 1
        $consolidation.Pillar | Should -Be 'Cost Optimization; Reliability'
        $consolidation.Effort | Should -Be 'Medium'
        $consolidation.DeepLinkUrl | Should -Match 'Microsoft_Azure_ContainerService'
        @($consolidation.RemediationSnippets).Count | Should -BeGreaterThan 0
        @($consolidation.EvidenceUris) | Should -Contain 'https://kubernetes.default.svc/apis/karpenter.sh/v1beta1/provisioners/default'
    }
}
