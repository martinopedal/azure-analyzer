#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-ADOConnections.ps1')
}

Describe 'Normalize-ADOConnections' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\ado-connections-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
        $partialFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\ado-connections-partial-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-ADOConnections -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 3
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to ado-connections' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'ado-connections'
            }
        }

        It 'sets Platform to ADO' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'ADO'
            }
        }

        It 'sets EntityType to ServiceConnection' {
            foreach ($r in $results) {
                $r.EntityType | Should -Be 'ServiceConnection'
            }
        }
    }

    Context 'CanonicalId normalization' {
        BeforeAll {
            $results = Normalize-ADOConnections -ToolResult $fixture
        }

        It 'lowercases EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }

        It 'uses ado canonical EntityId format with connectionId name' {
            foreach ($r in $results) {
                $r.EntityId | Should -Match '^ado://[^/]+/[^/]+/serviceconnection/[0-9a-f-]{36}$'
            }
        }

        It 'includes org/project/serviceconnection/connectionId in EntityId' {
            $results[0].EntityId | Should -BeExactly 'ado://contoso/my-project/serviceconnection/a1b2c3d4-0000-1111-2222-333344445555'
            $results[1].EntityId | Should -BeExactly 'ado://contoso/my-project/serviceconnection/b2c3d4e5-1111-2222-3333-444455556666'
            $results[2].EntityId | Should -BeExactly 'ado://contoso/my-project/serviceconnection/c3d4e5f6-2222-3333-4444-555566667777'
        }
    }

    Context 'Service Connection category' {
        BeforeAll {
            $results = Normalize-ADOConnections -ToolResult $fixture
        }

        It 'sets Category to Service Connection' {
            foreach ($r in $results) {
                $r.Category | Should -Be 'Service Connection'
            }
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-ADOConnections -ToolResult $fixture
        }

        It 'all findings are compliant (inventory mode)' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeTrue
            }
        }

        It 'all findings have Info severity' {
            foreach ($r in $results) {
                $r.Severity | Should -Be 'Info'
            }
        }

        It 'preserves Title' {
            $results[0].Title | Should -Not -BeNullOrEmpty
            $results[0].Title | Should -Match 'AzureRM'
        }

        It 'preserves Detail with auth info' {
            $results[0].Detail | Should -Match 'AuthScheme=WorkloadIdentityFederation'
            $results[1].Detail | Should -Match 'AuthScheme=PAT'
            $results[2].Detail | Should -Match 'AuthScheme=ServicePrincipal'
        }

        It 'maps Schema 2.2 ado-connections metadata fields' {
            $results[0].Pillar | Should -Be 'Security'
            $results[1].Impact | Should -Be 'High'
            $results[2].Effort | Should -Be 'Low'
            $results[0].DeepLinkUrl | Should -Match '_settings/adminservices'
            @($results[0].RemediationSnippets).Count | Should -BeGreaterThan 0
            @($results[0].EvidenceUris).Count | Should -Be 2
            @($results[0].BaselineTags) | Should -Contain 'Connection-Scoped'
            @($results[1].BaselineTags) | Should -Contain 'Connection-Shared'
            @($results[0].EntityRefs).Count | Should -Be 3
            $results[0].ToolVersion | Should -Be 'ado-rest-api-7.1'
        }
    }

    Context 'no Azure subscription context' {
        BeforeAll {
            $results = Normalize-ADOConnections -ToolResult $fixture
        }

        It 'does not set SubscriptionId for ADO connections' {
            foreach ($r in $results) {
                $r.SubscriptionId | Should -BeNullOrEmpty
            }
        }

        It 'does not set ResourceGroup for ADO connections' {
            foreach ($r in $results) {
                $r.ResourceGroup | Should -BeNullOrEmpty
            }
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-ADOConnections -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'ado-connections'; Status = 'Success'; Findings = $null }
            $results = Normalize-ADOConnections -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'ado-connections'; Status = 'Success'; Findings = @() }
            $results = Normalize-ADOConnections -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'processes PartialSuccess findings normally' {
            $results = Normalize-ADOConnections -ToolResult $partialFixture
            @($results).Count | Should -Be 1
            $results[0].EntityId | Should -BeExactly 'ado://contoso/open-project/serviceconnection/d4e5f6a7-3333-4444-5555-666677778888'
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'ado-connections'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        Source        = 'ado-connections'
                        ResourceId    = 'ado://myorg/myproj/serviceconnection/myconn'
                        Category      = 'Service Connection'
                        Title         = 'AzureRM connection: myconn'
                        Compliant     = $true
                        Severity      = 'Info'
                        Detail        = 'Type=AzureRM; AuthScheme=ServicePrincipal; AuthMechanism=SPN; IsShared=False'
                        SchemaVersion = '1.0'
                        AdoOrg        = 'myorg'
                        AdoProject    = 'myproj'
                    }
                )
            }
            $results = Normalize-ADOConnections -ToolResult $minimalInput
            @($results).Count | Should -Be 1
        }
    }

    Context 'Provenance tracking' {
        BeforeAll {
            $results = Normalize-ADOConnections -ToolResult $fixture
        }

        It 'sets Provenance.RunId consistently across all findings' {
            $runIds = @($results | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique)
            $runIds.Count | Should -Be 1
        }

        It 'sets Provenance.Source to ado-connections' {
            foreach ($r in $results) {
                $r.Provenance.Source | Should -Be 'ado-connections'
            }
        }
    }
}
