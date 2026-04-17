#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Trivy.ps1')
}

Describe 'Normalize-Trivy' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\trivy-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Trivy -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 4
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.0'
            }
        }

        It 'sets Source to trivy' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'trivy'
            }
        }

        It 'sets Platform to GitHub' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'GitHub'
            }
        }

        It 'sets EntityType to Repository' {
            foreach ($r in $results) {
                $r.EntityType | Should -Be 'Repository'
            }
        }
    }

    Context 'EntityId normalization' {
        BeforeAll {
            $results = Normalize-Trivy -ToolResult $fixture
        }

        It 'canonicalizes GitHub repo ResourceId for every finding' {
            $results[0].EntityId | Should -BeExactly 'github.com/test-org/test-repo'
        }

        It 'canonicalizes GitHub repo ResourceId' {
            $results[2].EntityId | Should -BeExactly 'github.com/test-org/test-repo'
        }

        It 'has a non-empty EntityId for all findings' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Supply Chain category' {
        BeforeAll {
            $results = Normalize-Trivy -ToolResult $fixture
        }

        It 'preserves Supply Chain category' {
            foreach ($r in $results) {
                $r.Category | Should -Be 'Supply Chain'
            }
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-Trivy -ToolResult $fixture
        }

        It 'preserves Compliant boolean (all false for vulnerabilities)' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeFalse
            }
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'Critical'
            $results[1].Severity | Should -Be 'High'
            $results[2].Severity | Should -Be 'Medium'
            $results[3].Severity | Should -Be 'Low'
        }

        It 'preserves Title with CVE ID and package name' {
            $results[0].Title | Should -Match 'CVE-2021-44228'
            $results[0].Title | Should -Match 'log4j-core'
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'preserves Remediation' {
            $results[0].Remediation | Should -Match 'Upgrade'
        }

        It 'preserves LearnMoreUrl' {
            $results[0].LearnMoreUrl | Should -Match 'avd\.aquasec\.com'
        }
    }

    Context 'Trivy has no Azure subscription context' {
        BeforeAll {
            $results = Normalize-Trivy -ToolResult $fixture
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

    Context 'Provenance tracking' {
        BeforeAll {
            $results = Normalize-Trivy -ToolResult $fixture
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
            $results = Normalize-Trivy -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'trivy'; Status = 'Success'; Findings = $null }
            $results = Normalize-Trivy -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'trivy'; Status = 'Success'; Findings = @() }
            $results = Normalize-Trivy -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'trivy'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source    = 'trivy'
                        ResourceId = 'github.com/test-org/test-repo'
                        Title    = 'CVE-2024-0001 (testpkg)'
                        Compliant = $false
                        Severity = 'High'
                    }
                )
            }
            $results = Normalize-Trivy -ToolResult $minimalInput
            @($results).Count | Should -Be 1
            $results[0].Source | Should -Be 'trivy'
        }
    }
}
