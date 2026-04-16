#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Scorecard.ps1')
}

Describe 'Normalize-Scorecard' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\scorecard-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 4
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.0'
            }
        }

        It 'sets Source to scorecard' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'scorecard'
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
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'lowercases EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }

        It 'has a non-empty EntityId even for empty ResourceId inputs' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Supply Chain category' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'preserves Supply Chain category' {
            foreach ($r in $results) {
                $r.Category | Should -Be 'Supply Chain'
            }
        }
    }

    Context 'score in Detail' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'preserves score information in Detail' {
            $results[0].Detail | Should -Match 'Score \d+/\d+'
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly' {
            $results[0].Compliant | Should -BeFalse
            $results[1].Compliant | Should -BeTrue
            $results[2].Compliant | Should -BeFalse
            $results[3].Compliant | Should -BeFalse
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'High'
            $results[1].Severity | Should -Be 'Info'
            $results[2].Severity | Should -Be 'Medium'
            $results[3].Severity | Should -Be 'Medium'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Scorecard has no Azure subscription context' {
        BeforeAll {
            $results = Normalize-Scorecard -ToolResult $fixture
        }

        It 'does not set SubscriptionId for GitHub checks' {
            foreach ($r in $results) {
                $r.SubscriptionId | Should -BeNullOrEmpty
            }
        }

        It 'does not set ResourceGroup for GitHub checks' {
            foreach ($r in $results) {
                $r.ResourceGroup | Should -BeNullOrEmpty
            }
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-Scorecard -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'scorecard'; Status = 'Success'; Findings = $null }
            $results = Normalize-Scorecard -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'scorecard'; Status = 'Success'; Findings = @() }
            $results = Normalize-Scorecard -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'scorecard'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'scorecard'
                        ResourceId   = ''
                        Category     = 'Supply Chain'
                        Title        = 'Test scorecard check'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Score 5/10. Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Scorecard -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }
}
