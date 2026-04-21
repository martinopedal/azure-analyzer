#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Zizmor.ps1')
}

Describe 'Normalize-Zizmor' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\zizmor-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Zizmor -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 3
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to zizmor' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'zizmor'
            }
        }

        It 'sets Platform to GitHub' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'GitHub'
            }
        }

        It 'sets EntityType to Workflow' {
            foreach ($r in $results) {
                $r.EntityType | Should -Be 'Workflow'
            }
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-Zizmor -ToolResult $fixture
        }

        It 'lowercases EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }

        It 'uses forward slashes in EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -Match '\\'
            }
        }

        It 'has a non-empty EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -BeNullOrEmpty
            }
        }

        It 'canonicalizes workflow file paths' {
            $results[0].EntityId | Should -BeExactly '.github/workflows/ci.yml'
            $results[2].EntityId | Should -BeExactly '.github/workflows/auto-label.yml'
        }
    }

    Context 'CI/CD Security category' {
        BeforeAll {
            $results = Normalize-Zizmor -ToolResult $fixture
        }

        It 'preserves CI/CD Security category' {
            foreach ($r in $results) {
                $r.Category | Should -Be 'CI/CD Security'
            }
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-Zizmor -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly (all false for security findings)' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeFalse
            }
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'High'
            $results[1].Severity | Should -Be 'Medium'
            $results[2].Severity | Should -Be 'High'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
            $results[0].Title | Should -Match 'expression-injection'
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'preserves LearnMoreUrl' {
            $results[0].LearnMoreUrl | Should -Match 'zizmor'
        }

        It 'preserves Remediation' {
            $results[0].Remediation | Should -Not -BeNullOrEmpty
        }
    }

    Context 'no Azure subscription context' {
        BeforeAll {
            $results = Normalize-Zizmor -ToolResult $fixture
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
            $results = Normalize-Zizmor -ToolResult $fixture
        }

        It 'sets Provenance.Source to zizmor' {
            foreach ($r in $results) {
                $r.Provenance.Source | Should -Be 'zizmor'
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
            $results = Normalize-Zizmor -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'zizmor'; Status = 'Success'; Findings = $null }
            $results = Normalize-Zizmor -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'zizmor'; Status = 'Success'; Findings = @() }
            $results = Normalize-Zizmor -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'zizmor'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'zizmor'
                        ResourceId   = '.github/workflows/test.yml'
                        Category     = 'CI/CD Security'
                        Title        = 'Test finding'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Zizmor -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }

    Context 'backslash path normalization' {
        It 'converts backslashes to forward slashes in EntityId' {
            $windowsPathInput = [PSCustomObject]@{
                Source   = 'zizmor'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'zizmor'
                        ResourceId   = '.github\workflows\ci.yml'
                        Category     = 'CI/CD Security'
                        Title        = 'Test finding'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Zizmor -ToolResult $windowsPathInput
            $results[0].EntityId | Should -BeExactly '.github/workflows/ci.yml'
        }
    }
}
