#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AzureCost.ps1'
}

Describe 'Invoke-AzureCost: error paths' {
    Context 'when Az.Accounts module is missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about Az.Accounts not installed' {
            $result.Message | Should -Match 'not installed'
        }
    }

    Context 'when not signed in to Azure' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { return $null }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'includes message about signing in' {
            $result.Message | Should -Match 'Not signed in'
        }
    }

    Context 'when Cost API call fails' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            Mock Invoke-AzRestMethod { throw 'Cost API failed' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'includes error message' {
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-AzureCost: success metadata' {
    BeforeAll {
        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
        Mock Invoke-AzRestMethod {
            [PSCustomObject]@{
                StatusCode = 200
                Content = (@{
                        value = @(
                            @{
                                properties = @{
                                    instanceId            = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cost/providers/Microsoft.Storage/storageAccounts/sa1'
                                    resourceName          = 'sa1'
                                    resourceType          = 'Microsoft.Storage/storageAccounts'
                                    consumedService       = $null
                                    resourceLocation      = 'westeurope'
                                    cost                  = 42.5
                                    costInBillingCurrency = 42.5
                                    billingCurrency       = 'USD'
                                }
                            }
                        )
                        nextLink = $null
                    } | ConvertTo-Json -Depth 10)
            }
        }

        $script:SuccessResult = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -TopN 1
    }

    It 'returns success with wrapper ToolVersion' {
        $script:SuccessResult.Status | Should -Be 'Success'
        $script:SuccessResult.ToolVersion | Should -Be 'Microsoft.Consumption/usageDetails@2021-10-01'
    }

    It 'stamps findings with CostCategory RuleId and ToolVersion' {
        $findings = @($script:SuccessResult.Findings)
        $findings.Count | Should -Be 2
        ($findings | Where-Object { $_.CostCategory -eq 'SubscriptionSpend' }).Count | Should -Be 1
        ($findings | Where-Object { $_.CostCategory -eq 'TopResourceSpend' }).Count | Should -Be 1
        @($findings | Where-Object { $_.RuleId -eq 'azure-cost-subscription-spend' }).Count | Should -Be 1
        @($findings | Where-Object { $_.RuleId -eq 'azure-cost-top-resource-spend' }).Count | Should -Be 1
        @($findings | Where-Object { $_.ToolVersion -eq 'Microsoft.Consumption/usageDetails@2021-10-01' }).Count | Should -Be 2
    }
}

