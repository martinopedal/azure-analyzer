#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Azqr.ps1')
}

Describe 'Normalize-Azqr' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\azqr-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Azqr -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 3
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to azqr' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'azqr'
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
            $results = Normalize-Azqr -ToolResult $fixture
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
            $results = Normalize-Azqr -ToolResult $fixture
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
            $results = Normalize-Azqr -ToolResult $fixture
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
            $results[0].Category | Should -Be 'Security'
            $results[1].Category | Should -Be 'HighAvailability'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'emits RuleId from RecommendationId' {
            $results[0].RuleId | Should -Be 'AZQR.SEC.001'
            $results[1].RuleId | Should -Be 'AZQR.REL.010'
        }

        It 'emits Schema 2.2 value fields' {
            $results[0].Impact | Should -Be 'High'
            $results[0].Effort | Should -Be 'Medium'
            $results[0].DeepLinkUrl | Should -Match '^https://portal\.azure\.com/'
            $results[0].ToolVersion | Should -Be '2.6.1'
        }

        It 'emits framework and pillar metadata' {
            $results[0].Pillar | Should -Be 'Security'
            $results[0].Frameworks | Should -Not -BeNullOrEmpty
            $results[0].Frameworks[0].kind | Should -Be 'WAF'
            $results[0].Frameworks[0].controlId | Should -Be 'Security'
            $results[1].Pillar | Should -Be 'Reliability'
            $results[2].Pillar | Should -Be 'OperationalExcellence'
        }

        It 'emits mitigation and MITRE fields when present' {
            $results[0].RemediationSnippets | Should -Not -BeNullOrEmpty
            $results[0].RemediationSnippets[0]['language'] | Should -Be 'AzureCLI'
            $results[0].EvidenceUris | Should -Contain 'https://learn.microsoft.com/azure/virtual-machines/disk-encryption-overview'
            $results[0].BaselineTags | Should -Contain 'release:ga'
            $results[0].MitreTactics | Should -Contain 'TA0001'
            $results[0].MitreTechniques | Should -Contain 'T1078'
            $results[0].EntityRefs | Should -Contain 'vm-web-01'
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-Azqr -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'azqr'; Status = 'Success'; Findings = $null }
            $results = Normalize-Azqr -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'azqr'; Status = 'Success'; Findings = @() }
            $results = Normalize-Azqr -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'azqr'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'azqr'
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
            $results = Normalize-Azqr -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }

        It 'uses canonical ARM-shaped fallback EntityId when ResourceId is missing' {
            $input = [PSCustomObject]@{
                Source   = 'azqr'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Id         = 'finding-123'
                        Category   = 'Security'
                        Title      = 'No resource id finding'
                        Compliant  = $false
                        Severity   = 'High'
                        Detail     = 'Test detail'
                    }
                )
            }

            $results = Normalize-Azqr -ToolResult $input
            @($results).Count | Should -Be 1
            $results[0].EntityId | Should -Match '^/subscriptions/[0-9a-f-]{36}/providers/microsoft\.resourcegraph/azqrfindings/finding-123$'
        }
    }
}
