#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-AlzQueries.ps1')
}

Describe 'Normalize-AlzQueries' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\alz-queries-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-AlzQueries -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 3
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to alz-queries' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'alz-queries'
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
            $results = Normalize-AlzQueries -ToolResult $fixture
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
            $results = Normalize-AlzQueries -ToolResult $fixture
        }

        It 'parses SubscriptionId from ARM ResourceId' {
            $withSub = @($results | Where-Object { $_.SubscriptionId })
            $withSub.Count | Should -Be 3
            foreach ($r in $withSub) {
                $r.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000001'
            }
        }

        It 'parses ResourceGroup from ARM ResourceId' {
            $withRg = @($results | Where-Object { $_.ResourceGroup })
            $withRg.Count | Should -Be 3
            foreach ($r in $withRg) {
                $r.ResourceGroup | Should -Be 'rg-prod-eastus'
            }
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-AlzQueries -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly' {
            $results[0].Compliant | Should -BeFalse
            $results[1].Compliant | Should -BeFalse
            $results[2].Compliant | Should -BeTrue
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'High'
            $results[1].Severity | Should -Be 'Medium'
            $results[2].Severity | Should -Be 'Info'
        }

        It 'preserves Category values' {
            $results[0].Category | Should -Be 'Networking'
            $results[1].Category | Should -Be 'Identity'
            $results[2].Category | Should -Be 'Security'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'emits Schema 2.2 value fields' {
            $results[0].Impact | Should -Be 'High'
            $results[0].Effort | Should -Be 'High'
            $results[1].Impact | Should -Be 'Medium'
            $results[2].Impact | Should -Be 'Low'
            $results[0].ToolVersion | Should -Be '1.0.0'
        }

        It 'emits framework and pillar metadata for ALZ governance' {
            $results[0].Pillar | Should -Be 'Security'
            $results[0].Frameworks | Should -Not -BeNullOrEmpty
            $results[0].Frameworks[0].kind | Should -Be 'ALZ'
            $results[0].Frameworks[0].controlId | Should -Be 'e8aa1e41-870d-4968-94c6-77be14f510ac'
        }

        It 'maps non-security categories to OperationalExcellence' {
            $input = [PSCustomObject]@{
                Source = 'alz-queries'
                Status = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Id         = '11111111-1111-1111-1111-111111111111'
                        Category   = 'Resource Organization'
                        Subcategory = 'Subscriptions'
                        Title      = 'Sandbox management group exists'
                        Severity   = 'Low'
                        Compliant  = $false
                        Detail     = '1 non-compliant resource'
                    }
                )
            }
            $mapped = Normalize-AlzQueries -ToolResult $input
            @($mapped).Count | Should -Be 1
            $mapped[0].Pillar | Should -Be 'OperationalExcellence'
        }

        It 'emits source deep links and evidence URIs' {
            $results[0].DeepLinkUrl | Should -Match '^https://github\.com/martinopedal/alz-graph-queries/search\?q='
            $results[0].EvidenceUris | Should -Contain 'https://learn.microsoft.com/azure/ddos-protection/ddos-protection-overview'
            $results[0].EvidenceUris | Should -Contain $results[0].DeepLinkUrl
        }

        It 'emits baseline tags from category and entity refs' {
            $results[0].BaselineTags | Should -Contain 'alz-category:networking'
            $results[0].BaselineTags | Should -Contain 'alz-subcategory:perimeter'
            $results[0].EntityRefs | Should -Contain $results[0].EntityId
        }

        It 'emits remediation snippets when text is available' {
            $results[0].RemediationSnippets | Should -Not -BeNullOrEmpty
            $results[0].RemediationSnippets[0]['language'] | Should -Be 'text'
            $results[0].RemediationSnippets[0]['code'] | Should -Match 'DDoS Protection Plan'
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-AlzQueries -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'alz-queries'; Status = 'Success'; Findings = $null }
            $results = Normalize-AlzQueries -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'alz-queries'; Status = 'Success'; Findings = @() }
            $results = Normalize-AlzQueries -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'alz-queries'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'alz-queries'
                        ResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-test'
                        Category     = 'Security'
                        Title        = 'Test finding'
                        Compliant    = $false
                        Severity     = 'High'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-AlzQueries -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }
}
