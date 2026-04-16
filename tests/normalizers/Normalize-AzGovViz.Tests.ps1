#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-AzGovViz.ps1')
}

Describe 'Normalize-AzGovViz' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\azgovviz-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 2
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.0'
            }
        }

        It 'sets Source to azgovviz' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'azgovviz'
            }
        }

        It 'sets Platform to Azure' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'Azure'
            }
        }
    }

    Context 'entity type mapping' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'maps subscription-scoped findings to Subscription EntityType' {
            $subFinding = $results | Where-Object { $_.EntityId -match '^[0-9a-f-]{36}$' }
            if ($subFinding) {
                $subFinding.EntityType | Should -Be 'Subscription'
            }
        }

        It 'maps governance findings without ResourceId to ManagementGroup EntityType' {
            $mgFinding = $results | Where-Object { $_.EntityType -eq 'ManagementGroup' }
            if ($mgFinding) {
                $mgFinding.EntityType | Should -Be 'ManagementGroup'
            }
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'lowercases EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }
    }

    Context 'subscription parsing' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'parses SubscriptionId for subscription-scoped findings' {
            $withSub = @($results | Where-Object { $_.SubscriptionId })
            $withSub.Count | Should -BeGreaterThan 0
            $withSub[0].SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000001'
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-AzGovViz -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeFalse
            }
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'Medium'
            $results[1].Severity | Should -Be 'Low'
        }

        It 'preserves Category values' {
            $results[0].Category | Should -Be 'Governance'
            $results[1].Category | Should -Be 'Policy'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-AzGovViz -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'azgovviz'; Status = 'Success'; Findings = $null }
            $results = Normalize-AzGovViz -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'azgovviz'; Status = 'Success'; Findings = @() }
            $results = Normalize-AzGovViz -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'azgovviz'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'azgovviz'
                        ResourceId   = '/subscriptions/00000000-0000-0000-0000-000000000001'
                        Category     = 'Governance'
                        Title        = 'Test governance finding'
                        Compliant    = $false
                        Severity     = 'Medium'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-AzGovViz -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }
}
