#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-WARA.ps1')
}

Describe 'Normalize-WARA' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\wara-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-WARA -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 2
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to wara' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'wara'
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

    Context 'WARA-specific: all findings are non-compliant' {
        BeforeAll {
            $results = Normalize-WARA -ToolResult $fixture
        }

        It 'has no compliant findings (WARA never reports compliant)' {
            $compliant = @($results | Where-Object { $_.Compliant -eq $true })
            $compliant.Count | Should -Be 0
        }

        It 'all findings have Compliant set to false' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeFalse
            }
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-WARA -ToolResult $fixture
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
            $results = Normalize-WARA -ToolResult $fixture
        }

        It 'parses SubscriptionId from ARM ResourceId' {
            $withSub = @($results | Where-Object { $_.SubscriptionId })
            $withSub.Count | Should -Be 2
            foreach ($r in $withSub) {
                $r.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000001'
            }
        }

        It 'parses ResourceGroup from ARM ResourceId' {
            $withRg = @($results | Where-Object { $_.ResourceGroup })
            $withRg.Count | Should -Be 2
            foreach ($r in $withRg) {
                $r.ResourceGroup | Should -Be 'rg-prod-eastus'
            }
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-WARA -ToolResult $fixture
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'High'
            $results[1].Severity | Should -Be 'High'
        }

        It 'preserves Category values' {
            $results[0].Category | Should -Be 'Reliability'
            $results[1].Category | Should -Be 'Security'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'maps WAF framework metadata to Schema 2.2 fields' {
            @($results[0].Frameworks).Count | Should -Be 1
            $results[0].Frameworks[0].Name | Should -Be 'WAF'
            $results[0].Frameworks[0].Pillars | Should -Contain 'Reliability'
            $results[0].Frameworks[0].Controls | Should -Contain 'rec-reliability-vm'
            $results[0].Pillar | Should -Be 'Reliability'
            $results[0].Impact | Should -Be 'High'
            $results[0].Effort | Should -Be 'Medium'
            $results[0].DeepLinkUrl | Should -Be 'https://learn.microsoft.com/azure/well-architected/reliability/design-redundancy'
            $results[0].ToolVersion | Should -Be '2.4.0'
        }

        It 'emits remediation snippets and baseline tags' {
            @($results[0].RemediationSnippets).Count | Should -Be 2
            $results[0].RemediationSnippets[0].language | Should -Be 'text'
            $results[0].BaselineTags | Should -Contain 'service-category:compute'
        }

        It 'emits canonical EntityRefs' {
            @($results[0].EntityRefs).Count | Should -Be 2
            $results[0].EntityRefs[0] | Should -Match '^/subscriptions/'
            $results[0].EntityRefs[0] | Should -BeExactly $results[0].EntityRefs[0].ToLowerInvariant()
        }
    }

    Context 'pillar enumeration coverage' {
        It 'normalizes all 5 WAF pillars' {
            $allPillarsInput = [PSCustomObject]@{
                Source      = 'wara'
                Status      = 'Success'
                ToolVersion = '2.4.0'
                Findings    = @(
                    [PSCustomObject]@{ Id = 'p1'; RecommendationId = 'c1'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'; Category = 'Reliability'; Pillar = 'Reliability'; Title = 'R'; Compliant = $false; Severity = 'High'; Detail = 'd' },
                    [PSCustomObject]@{ Id = 'p2'; RecommendationId = 'c2'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa1'; Category = 'Security'; Pillar = 'Security'; Title = 'S'; Compliant = $false; Severity = 'High'; Detail = 'd' },
                    [PSCustomObject]@{ Id = 'p3'; RecommendationId = 'c3'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Sql/servers/sql1'; Category = 'Cost'; Pillar = 'Cost Optimization'; Title = 'C'; Compliant = $false; Severity = 'Medium'; Detail = 'd' },
                    [PSCustomObject]@{ Id = 'p4'; RecommendationId = 'c4'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet1'; Category = 'Performance'; Pillar = 'Performance Efficiency'; Title = 'P'; Compliant = $false; Severity = 'Medium'; Detail = 'd' },
                    [PSCustomObject]@{ Id = 'p5'; RecommendationId = 'c5'; ResourceId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv1'; Category = 'Operational'; Pillar = 'Operational Excellence'; Title = 'O'; Compliant = $false; Severity = 'Low'; Detail = 'd' }
                )
            }

            $results = Normalize-WARA -ToolResult $allPillarsInput
            $pillars = @($results.Pillar | Select-Object -Unique | Sort-Object)
            $pillars | Should -Be @('Cost', 'Operational', 'Performance', 'Reliability', 'Security')
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-WARA -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'wara'; Status = 'Success'; Findings = $null }
            $results = Normalize-WARA -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'wara'; Status = 'Success'; Findings = @() }
            $results = Normalize-WARA -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'wara'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'wara'
                        ResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-test'
                        Category     = 'Reliability'
                        Title        = 'Test finding'
                        Compliant    = $false
                        Severity     = 'High'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-WARA -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }
}
