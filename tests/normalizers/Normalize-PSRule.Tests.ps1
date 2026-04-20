#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-PSRule.ps1')
}

Describe 'Normalize-PSRule' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\psrule-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-PSRule -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 3
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.1'
            }
        }

        It 'sets Source to psrule' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'psrule'
            }
        }

        It 'sets Platform to Azure' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'Azure'
            }
        }

        It 'sets EntityType to AzureResource' {
            foreach ($r in $results) {
                $r.EntityType | Should -Be 'AzureResource'
            }
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-PSRule -ToolResult $fixture
        }

        It 'lowercases the ARM ResourceId into EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }

        It 'does not have a trailing slash on EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -Match '/$'
            }
        }
    }

    Context 'ARM path parsing' {
        BeforeAll {
            $results = Normalize-PSRule -ToolResult $fixture
        }

        It 'parses SubscriptionId from ARM ResourceId' {
            $withSub = @($results | Where-Object { $_.SubscriptionId })
            $withSub.Count | Should -BeGreaterThan 0
            foreach ($r in $withSub) {
                $r.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000001'
            }
        }

        It 'parses ResourceGroup from ARM ResourceId' {
            $withRg = @($results | Where-Object { $_.ResourceGroup })
            $withRg.Count | Should -BeGreaterThan 0
            foreach ($r in $withRg) {
                $r.ResourceGroup | Should -Be 'rg-prod-eastus'
            }
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-PSRule -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly' {
            $results[0].Compliant | Should -BeFalse
            $results[1].Compliant | Should -BeTrue
            $results[2].Compliant | Should -BeFalse
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'High'
            $results[1].Severity | Should -Be 'Info'
            $results[2].Severity | Should -Be 'High'
        }

        It 'maps PSRule rule name to Category' {
            $results[0].Category | Should -Be 'Azure.SQL.TDE'
            $results[1].Category | Should -Be 'Azure.NSG.Associated'
            $results[2].Category | Should -Be 'Azure.AppService.MinTLS'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-PSRule -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'psrule'; Status = 'Success'; Findings = $null }
            $results = Normalize-PSRule -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'psrule'; Status = 'Success'; Findings = @() }
            $results = Normalize-PSRule -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'psrule'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'psrule'
                        ResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test/providers/Microsoft.Network/networkSecurityGroups/nsg-test'
                        Category     = 'Azure.NSG.AnyInbound'
                        Title        = 'Test finding'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-PSRule -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }
}
