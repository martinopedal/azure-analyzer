#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Get-AksClustersInScope' {
    BeforeAll {
        $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
        . (Join-Path $script:RepoRoot 'modules' 'shared' 'AksDiscovery.ps1')
    }

    It 'returns direct cluster metadata when ClusterArmIds are provided' {
        $clusterId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod'
        $clusters = @(Get-AksClustersInScope -SubscriptionId '00000000-0000-0000-0000-000000000000' -ClusterArmIds @($clusterId))
        $clusters.Count | Should -Be 1
        $clusters[0].id | Should -Be $clusterId
        $clusters[0].resourceGroup | Should -Be 'rg-aks'
        $clusters[0].name | Should -Be 'aks-prod'
    }

    It 'uses ARG and filters by ResourceGroup and ClusterName' {
        Mock Get-Module { [pscustomobject]@{ Name = 'Az.ResourceGraph' } } -ParameterFilter { $ListAvailable -and $Name -eq 'Az.ResourceGraph' }
        Mock Import-Module {}
        Mock Search-AzGraph {
            @(
                [pscustomobject]@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod'
                    name = 'aks-prod'
                    resourceGroup = 'rg-aks'
                    subscriptionId = '00000000-0000-0000-0000-000000000000'
                    location = 'westeurope'
                    workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-law/providers/Microsoft.OperationalInsights/workspaces/law-prod'
                }
            )
        }

        $clusters = @(Get-AksClustersInScope -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'rg-aks' -ClusterName 'aks-prod')
        $clusters.Count | Should -Be 1
        $clusters[0].workspaceResourceId | Should -Match '/workspaces/law-prod$'
    }

    It 'throws when Az.ResourceGraph is required but unavailable' {
        Mock Get-Module { $null } -ParameterFilter { $ListAvailable -and $Name -eq 'Az.ResourceGraph' }
        { Get-AksClustersInScope -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'rg' } | Should -Throw '*Az.ResourceGraph*'
    }
}
