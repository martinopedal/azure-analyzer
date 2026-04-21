#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Gitleaks.ps1')
}

Describe 'Normalize-Gitleaks' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\gitleaks-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Gitleaks -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 3
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to gitleaks' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'gitleaks'
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

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-Gitleaks -ToolResult $fixture
        }

        It 'uses canonical repository EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -Be 'github.com/local/local'
            }
        }

        It 'lowercases ResourceId path' {
            foreach ($r in $results) {
                $r.ResourceId | Should -BeExactly $r.ResourceId.ToLowerInvariant()
            }
        }

        It 'uses forward slashes in ResourceId path' {
            foreach ($r in $results) {
                $r.ResourceId | Should -Not -Match '\\'
            }
        }

        It 'has non-empty ResourceId path' {
            foreach ($r in $results) {
                $r.ResourceId | Should -Not -BeNullOrEmpty
            }
        }

        It 'canonicalizes repository EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly 'github.com/local/local'
            }
        }

        It 'normalizes ResourceId with canonical slashes/lowercase' {
            $results[0].ResourceId | Should -BeExactly 'github.com/test-org/test-repo'
            $results[1].ResourceId | Should -BeExactly 'github.com/test-org/test-repo'
            $results[2].ResourceId | Should -BeExactly 'github.com/test-org/test-repo'
        }
    }

    Context 'Secret Detection category' {
        BeforeAll {
            $results = Normalize-Gitleaks -ToolResult $fixture
        }

        It 'preserves Secret Detection category' {
            foreach ($r in $results) {
                $r.Category | Should -Be 'Secret Detection'
            }
        }
    }

    Context 'severity mapping' {
        BeforeAll {
            $results = Normalize-Gitleaks -ToolResult $fixture
        }

        It 'maps High severity for secret findings' {
            $results[0].Severity | Should -Be 'High'
            $results[1].Severity | Should -Be 'High'
        }

        It 'maps Medium severity for non-secret findings' {
            $results[2].Severity | Should -Be 'Medium'
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-Gitleaks -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly (all false for secret findings)' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeFalse
            }
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
            $results[0].Title | Should -Match 'config\.js'
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'preserves Remediation' {
            $results[0].Remediation | Should -Not -BeNullOrEmpty
            $results[0].Remediation | Should -Match 'Rotate'
        }

        It 'preserves LearnMoreUrl' {
            $results[0].LearnMoreUrl | Should -Match 'gitleaks'
        }

        It 'preserves finding Id from fingerprint' {
            $results[0].Id | Should -Not -BeNullOrEmpty
        }
    }

    Context 'no Azure subscription context' {
        BeforeAll {
            $results = Normalize-Gitleaks -ToolResult $fixture
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

    Context 'provenance tracking' {
        BeforeAll {
            $results = Normalize-Gitleaks -ToolResult $fixture
        }

        It 'sets Provenance.Source to gitleaks' {
            foreach ($r in $results) {
                $r.Provenance.Source | Should -Be 'gitleaks'
            }
        }

        It 'sets a non-empty Provenance.RunId' {
            foreach ($r in $results) {
                $r.Provenance.RunId | Should -Not -BeNullOrEmpty
            }
        }

        It 'shares the same RunId across all findings' {
            $runIds = $results | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique
            @($runIds).Count | Should -Be 1
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-Gitleaks -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'gitleaks'; Status = 'Success'; Findings = $null }
            $results = Normalize-Gitleaks -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'gitleaks'; Status = 'Success'; Findings = @() }
            $results = Normalize-Gitleaks -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'gitleaks'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'gitleaks'
                        ResourceId   = 'github.com/test-org/test-repo'
                        Category     = 'Secret Detection'
                        Title        = 'Secret detected'
                        Compliant    = $false
                        Severity     = 'High'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Gitleaks -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }

    Context 'backslash path normalization' {
        It 'converts backslashes to forward slashes in EntityId' {
            $windowsPathInput = [PSCustomObject]@{
                Source   = 'gitleaks'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'gitleaks'
                        ResourceId   = 'github.com\test-org\test-repo'
                        Category     = 'Secret Detection'
                        Title        = 'Secret found'
                        Compliant    = $false
                        Severity     = 'High'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Gitleaks -ToolResult $windowsPathInput
            $results[0].EntityId | Should -Be 'github.com/local/local'
            $results[0].ResourceId | Should -BeExactly 'github.com/test-org/test-repo'
        }
    }
}
