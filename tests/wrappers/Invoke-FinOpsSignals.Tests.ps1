#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-FinOpsSignals.ps1'
    $script:QueryFile = Join-Path $script:RepoRoot 'queries' 'finops-unattached-managed-disks.json'
}

Describe 'Invoke-FinOpsSignals: wrapper behavior' {
    Context 'when Az.ResourceGraph module is missing' {
        BeforeAll {
            Mock Get-Module {
                param([string]$Name, [switch]$ListAvailable)
                if ($Name -eq 'Az.ResourceGraph' -and $ListAvailable) { return $null }
                return [PSCustomObject]@{ Name = $Name }
            }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -QueryFiles @($script:QueryFile)
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'mentions Az.ResourceGraph not installed' {
            $result.Message | Should -Match 'Az.ResourceGraph'
        }
    }

    Context 'with mocked cost API and ARG response' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Mock' } }
            Mock Import-Module {}
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'test@contoso.com' } }
            Mock Invoke-AzRestMethod {
                [PSCustomObject]@{
                    StatusCode = 200
                    Content = (@{
                        properties = @{
                            currency = 'USD'
                            columns  = @(
                                @{ name = 'ResourceId' },
                                @{ name = 'PreTaxCost' }
                            )
                            rows = @(
                                @('/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-finops/providers/microsoft.compute/disks/orphaned-disk-01', 72.5)
                            )
                        }
                    } | ConvertTo-Json -Depth 10)
                }
            } -ParameterFilter { $Method -eq 'POST' }
            Mock Search-AzGraph {
                @(
                    [PSCustomObject]@{
                        id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-finops/providers/Microsoft.Compute/disks/orphaned-disk-01'
                        name = 'orphaned-disk-01'
                        type = 'microsoft.compute/disks'
                        resourceGroup = 'rg-finops'
                        subscriptionId = '11111111-1111-1111-1111-111111111111'
                        location = 'westeurope'
                        detectedReason = 'Managed disk is unattached and older than 30 days'
                        compliant = $false
                    }
                )
            }

            $result = & $script:Wrapper -SubscriptionId '11111111-1111-1111-1111-111111111111' -QueryFiles @($script:QueryFile)
        }

        It 'returns a v1 envelope with Source finops' {
            $result.SchemaVersion | Should -Be '1.0'
            $result.Source | Should -Be 'finops'
        }

        It 'returns Success or PartialSuccess and at least one finding' {
            $result.Status | Should -BeIn @('Success', 'PartialSuccess')
            @($result.Findings).Count | Should -BeGreaterThan 0
        }

        It 'adds estimated monthly cost fields to findings' {
            $f = @($result.Findings)[0]
            $f.PSObject.Properties.Name | Should -Contain 'EstimatedMonthlyCost'
            $f.PSObject.Properties.Name | Should -Contain 'DetectionCategory'
            $f.EstimatedMonthlyCost | Should -BeGreaterThan 0
            $f.Currency | Should -Be 'USD'
            $f.Compliant | Should -BeFalse
        }
    }
}
