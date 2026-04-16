#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-AzureCost.ps1')
}

Describe 'Normalize-AzureCost' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\azure-cost-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-AzureCost -ToolResult $fixture
        }

        It 'emits one subscription finding plus one per resource' {
            @($results).Count | Should -Be 4
        }

        It 'sets source, severity and category for all findings' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'azure-cost'
                $r.Severity | Should -Be 'Info'
                $r.Category | Should -Be 'Cost'
                $r.Compliant | Should -BeTrue
            }
        }

        It 'emits a subscription informational finding' {
            $subscriptionFinding = $results | Where-Object { $_.EntityType -eq 'Subscription' }
            $subscriptionFinding | Should -Not -BeNullOrEmpty
            $subscriptionFinding.EntityId | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000001'
            $subscriptionFinding.MonthlyCost | Should -Be 5123.45
            $subscriptionFinding.Currency | Should -Be 'USD'
        }

        It 'emits AzureResource findings with monthly cost and currency metadata' {
            $resourceFindings = @($results | Where-Object { $_.EntityType -eq 'AzureResource' })
            $resourceFindings.Count | Should -Be 3
            foreach ($r in $resourceFindings) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
                $r.MonthlyCost | Should -BeGreaterThan 0
                $r.Currency | Should -Be 'USD'
            }
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-AzureCost -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array when no cost data is available' {
            $empty = [PSCustomObject]@{
                Source            = 'azure-cost'
                Status            = 'Success'
                SubscriptionId    = '00000000-0000-0000-0000-000000000001'
                SubscriptionTotal = $null
                ResourceCosts     = @()
            }
            $results = Normalize-AzureCost -ToolResult $empty
            @($results).Count | Should -Be 0
        }
    }

    Context 'resource cap behavior' {
        It 'limits emitted resource findings to top 20 when wrapper returns top 20' {
            $manyResources = 1..20 | ForEach-Object {
                [PSCustomObject]@{
                    ResourceId   = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-$($_)"
                    ResourceName = "vm-$($_)"
                    MonthlyCost  = (1000 - $_)
                    Currency     = 'USD'
                }
            }
            $toolResult = [PSCustomObject]@{
                Source            = 'azure-cost'
                Status            = 'Success'
                SubscriptionId    = '00000000-0000-0000-0000-000000000001'
                Days              = 30
                Currency          = 'USD'
                SubscriptionTotal = 9999.99
                ResourceCosts     = $manyResources
            }

            $results = Normalize-AzureCost -ToolResult $toolResult
            @($results | Where-Object { $_.EntityType -eq 'AzureResource' }).Count | Should -Be 20
        }
    }
}
