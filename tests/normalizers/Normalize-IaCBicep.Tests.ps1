#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IaCBicep.ps1')
}

Describe 'Normalize-IaCBicep' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\iac-bicep-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-IaCBicep -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 5
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to bicep-iac' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'bicep-iac'
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

    Context 'EntityId normalization' {
        BeforeAll {
            $results = Normalize-IaCBicep -ToolResult $fixture
        }

        It 'uses synthetic ARM deployment EntityId for IaC files' {
            foreach ($r in $results) {
                $r.EntityId | Should -Match '^/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/iac-bicep/providers/microsoft\.resources/deployments/'
            }
        }

        It 'has a non-empty EntityId for all findings' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -BeNullOrEmpty
            }
        }

        It 'normalizes deployment token to lowercase' {
            $results[0].EntityId | Should -BeExactly '/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/iac-bicep/providers/microsoft.resources/deployments/infra-main-bicep'
        }
    }

    Context 'category preservation' {
        BeforeAll {
            $results = Normalize-IaCBicep -ToolResult $fixture
        }

        It 'preserves per-finding categories' {
            @($results | Where-Object { $_.Category -eq 'Security' }).Count | Should -BeGreaterThan 0
            @($results | Where-Object { $_.Category -eq 'Cost' }).Count | Should -BeGreaterThan 0
            @($results | Where-Object { $_.Category -eq 'Operations' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'severity mapping from Error Warning Info' {
        BeforeAll {
            $results = Normalize-IaCBicep -ToolResult $fixture
        }

        It 'maps Error to High severity' {
            @($results | Where-Object { $_.Severity -eq 'High' }).Count | Should -BeGreaterThan 0
        }

        It 'maps Warning to Medium severity' {
            @($results | Where-Object { $_.Severity -eq 'Medium' }).Count | Should -BeGreaterThan 0
        }

        It 'maps Info to Low severity' {
            @($results | Where-Object { $_.Severity -eq 'Low' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-IaCBicep -ToolResult $fixture
        }

        It 'preserves Compliant boolean' {
            $results[0].Compliant | Should -BeFalse
        }

        It 'preserves compliant true for info findings' {
            $results[4].Compliant | Should -BeTrue
        }

        It 'preserves Title' {
            $results[0].Title | Should -Match 'Bicep build error'
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'preserves Remediation' {
            $results[0].Remediation | Should -Not -BeNullOrEmpty
        }

        It 'preserves LearnMoreUrl' {
            $results[0].LearnMoreUrl | Should -Match 'learn\.microsoft\.com'
        }

        It 'maps Schema 2.2 ETL fields' {
            foreach ($r in $results) {
                $r.RuleId | Should -Not -BeNullOrEmpty
                $r.Pillar | Should -Not -BeNullOrEmpty
                $r.Impact | Should -Not -BeNullOrEmpty
                $r.Effort | Should -Be 'Low'
                $r.DeepLinkUrl | Should -Not -BeNullOrEmpty
                @($r.Frameworks).Count | Should -BeGreaterThan 0
                @($r.BaselineTags).Count | Should -BeGreaterThan 2
                @($r.EvidenceUris).Count | Should -BeGreaterThan 0
                @($r.EntityRefs).Count | Should -BeGreaterThan 0
                $r.ToolVersion | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Provenance tracking' {
        BeforeAll {
            $results = Normalize-IaCBicep -ToolResult $fixture
        }

        It 'sets Provenance with RunId' {
            foreach ($r in $results) {
                $r.Provenance | Should -Not -BeNullOrEmpty
                $r.Provenance.RunId | Should -Not -BeNullOrEmpty
            }
        }

        It 'uses consistent RunId across all findings' {
            $runIds = $results | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique
            @($runIds).Count | Should -Be 1
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-IaCBicep -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'bicep-iac'; Status = 'Success'; Findings = $null }
            $results = Normalize-IaCBicep -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'bicep-iac'; Status = 'Success'; Findings = @() }
            $results = Normalize-IaCBicep -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'bicep-iac'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        ResourceId = 'test.bicep'
                        Title      = 'Bicep error: test.bicep'
                        Compliant  = $false
                        Severity   = 'High'
                    }
                )
            }
            $results = Normalize-IaCBicep -ToolResult $minimalInput
            @($results).Count | Should -Be 1
            $results[0].Source | Should -Be 'bicep-iac'
        }
    }

    Context 'no Azure subscription context' {
        BeforeAll {
            $results = Normalize-IaCBicep -ToolResult $fixture
        }

        It 'does not set SubscriptionId' {
            foreach ($r in $results) {
                $r.SubscriptionId | Should -BeNullOrEmpty
            }
        }

        It 'does not set ResourceGroup' {
            foreach ($r in $results) {
                $r.ResourceGroup | Should -BeNullOrEmpty
            }
        }
    }
}
