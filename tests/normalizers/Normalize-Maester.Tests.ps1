#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Maester.ps1')
}

Describe 'Normalize-Maester' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\maester-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Maester -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 3
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.1'
            }
        }

        It 'sets Source to maester' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'maester'
            }
        }

        It 'sets Platform to Entra for tenant-scoped identity checks' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'Entra'
            }
        }
    }

    Context 'entity type mapping for tenant-scoped checks' {
        BeforeAll {
            $results = Normalize-Maester -ToolResult $fixture
        }

        It 'uses the Tenant EntityType' {
            foreach ($r in $results) {
                $r.EntityType | Should -Be 'Tenant'
            }
        }

        It 'sets Platform to Entra' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'Entra'
            }
        }

        It 'has a non-empty EntityId even for empty ResourceId inputs' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-Maester -ToolResult $fixture
        }

        It 'lowercases EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-Maester -ToolResult $fixture
        }

        It 'preserves Compliant boolean correctly' {
            $results[0].Compliant | Should -BeFalse
            $results[1].Compliant | Should -BeFalse
            $results[2].Compliant | Should -BeTrue
        }

        It 'preserves Severity values' {
            $results[0].Severity | Should -Be 'Critical'
            $results[1].Severity | Should -Be 'High'
            $results[2].Severity | Should -Be 'Info'
        }

        It 'preserves Category values' {
            $results[0].Category | Should -Be 'Identity'
            $results[1].Category | Should -Be 'Security'
            $results[2].Category | Should -Be 'Identity'
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }
    }

    Context 'tenant-scoped checks have no SubscriptionId' {
        BeforeAll {
            $results = Normalize-Maester -ToolResult $fixture
        }

        It 'does not set SubscriptionId for Entra checks' {
            foreach ($r in $results) {
                $r.SubscriptionId | Should -BeNullOrEmpty
            }
        }

        It 'does not set ResourceGroup for Entra checks' {
            foreach ($r in $results) {
                $r.ResourceGroup | Should -BeNullOrEmpty
            }
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-Maester -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'maester'; Status = 'Success'; Findings = $null }
            $results = Normalize-Maester -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'maester'; Status = 'Success'; Findings = @() }
            $results = Normalize-Maester -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'maester'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source       = 'maester'
                        ResourceId   = ''
                        Category     = 'Identity'
                        Title        = 'Test identity check'
                        Compliant    = $false
                        Severity     = 'High'
                        Detail       = 'Test detail'
                        SchemaVersion = '1.0'
                    }
                )
            }
            $results = Normalize-Maester -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }
}
