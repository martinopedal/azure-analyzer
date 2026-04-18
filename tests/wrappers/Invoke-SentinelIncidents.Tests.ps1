#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-SentinelIncidents.ps1'
}

Describe 'Invoke-SentinelIncidents: error paths' {
    Context 'when Az.Accounts module is missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about Az.Accounts not installed' {
            $result.Message | Should -Match 'not installed'
        }
    }

    Context 'when not signed in to Azure' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { return $null }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'includes message about signing in' {
            $result.Message | Should -Match 'Not signed in'
        }
    }

    Context 'when WorkspaceResourceId format is invalid' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/bad-format'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'includes message about invalid format' {
            $result.Message | Should -Match 'Invalid WorkspaceResourceId'
        }
    }

    Context 'when Log Analytics query API call fails' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            Mock Invoke-AzRestMethod { throw 'API call failed' }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'includes error message' {
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }

    Context 'when API returns HTTP 404 (table not found)' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            Mock Invoke-AzRestMethod {
                [PSCustomObject]@{ StatusCode = 404; Content = '{"error":{"code":"ResourceNotFound"}}' }
            }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'mentions table not available' {
            $result.Message | Should -Match 'not available'
        }
    }

    Context 'when API returns HTTP 400 with SemanticError table-not-found' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            Mock Invoke-AzRestMethod {
                [PSCustomObject]@{
                    StatusCode = 400
                    Content = '{"error":{"code":"BadArgumentError","innererror":{"code":"SemanticError","message":"''SecurityIncident'' could not be resolved."}}}'
                }
            }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'mentions Sentinel may not be enabled' {
            $result.Message | Should -Match 'Sentinel may not be enabled'
        }
    }

    Context 'when API returns HTTP 400 for non-table-related errors (permission, malformed)' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            Mock Invoke-AzRestMethod {
                [PSCustomObject]@{
                    StatusCode = 400
                    Content = '{"error":{"code":"BadArgumentError","message":"The request had some invalid properties"}}'
                }
            }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'returns Status = Failed (not Skipped)' {
            $result.Status | Should -Be 'Failed'
        }

        It 'includes the error detail' {
            $result.Message | Should -Match 'query'
        }
    }

    Context 'when query returns empty result set (no incidents)' {
        BeforeAll {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com' } }
            Mock Invoke-AzRestMethod {
                $emptyResult = @{
                    tables = @(
                        @{
                            columns = @(
                                @{ name = 'IncidentNumber'; type = 'int' }
                                @{ name = 'Title'; type = 'string' }
                            )
                            rows = @()
                        }
                    )
                } | ConvertTo-Json -Depth 10
                [PSCustomObject]@{ StatusCode = 200; Content = $emptyResult }
            }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'returns Status = Success' {
            $result.Status | Should -Be 'Success'
        }

        It 'returns zero Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'message indicates no incidents' {
            $result.Message | Should -Match 'No active Sentinel incidents'
        }
    }

    Context 'v1 shape contract' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
        }

        It 'has SchemaVersion 1.0' {
            $result.SchemaVersion | Should -Be '1.0'
        }

        It 'has Source = sentinel-incidents' {
            $result.Source | Should -Be 'sentinel-incidents'
        }

        It 'has Timestamp in ISO 8601 format' {
            $result.Timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T'
        }

        It 'has Subscription extracted from workspace ARM ID' {
            $result.Subscription | Should -Be '00000000-0000-0000-0000-000000000000'
        }
    }
}
