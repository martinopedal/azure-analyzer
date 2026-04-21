#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-ADOServiceConnections.ps1'
}

Describe 'Invoke-ADOServiceConnections: error paths' {
    Context 'when ADO PAT is missing' {
        BeforeAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\AZURE_DEVOPS_EXT_PAT -ErrorAction SilentlyContinue
            Remove-Item Env:\AZ_DEVOPS_PAT -ErrorAction SilentlyContinue
            $result = & $script:Wrapper -AdoOrg 'testorg'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about missing PAT' {
            $result.Message | Should -Match 'No ADO PAT'
        }
    }

    Context 'when ADO API call fails' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest { throw 'API call failed' }
            $result = & $script:Wrapper -AdoOrg 'testorg'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes error message' {
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }

    Context 'when ADO API returns garbage' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = 'not json at all' } }
            $result = & $script:Wrapper -AdoOrg 'testorg'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }
    }
}

Describe 'Invoke-ADOServiceConnections: success metadata mapping' {
    Context 'when service endpoints are returned' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest {
                [PSCustomObject]@{
                    Content = (@{
                            value = @(
                                @{
                                    id            = '11111111-1111-1111-1111-111111111111'
                                    name          = 'azure-wif'
                                    type          = 'AzureRM'
                                    isShared      = $false
                                    authorization = @{
                                        scheme     = 'WorkloadIdentityFederation'
                                        parameters = @{}
                                    }
                                },
                                @{
                                    id            = '22222222-2222-2222-2222-222222222222'
                                    name          = 'github-token'
                                    type          = 'GitHub'
                                    isShared      = $true
                                    authorization = @{
                                        scheme     = 'Token'
                                        parameters = @{}
                                    }
                                }
                            )
                        } | ConvertTo-Json -Depth 10)
                    Headers = @{}
                }
            } -ParameterFilter { $Uri -like '*_apis/serviceendpoint/endpoints*' }

            $result = & $script:Wrapper -AdoOrg 'contoso' -AdoProject 'my-project'
            $findings = @($result.Findings)
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Status = Success' {
            $result.Status | Should -Be 'Success'
        }

        It 'emits Schema 2.2 additive metadata in v1 findings' {
            $findings.Count | Should -Be 2
            $findings[0].Pillar | Should -Be 'Security'
            $findings[0].Impact | Should -Be 'Low'
            $findings[1].Impact | Should -Be 'High'
            $findings[0].Effort | Should -Be 'Low'
            $findings[1].Effort | Should -Be 'Medium'
            $findings[1].DeepLinkUrl | Should -Be 'https://dev.azure.com/contoso/my-project/_settings/adminservices?resourceId=22222222-2222-2222-2222-222222222222'
            @($findings[0].RemediationSnippets).Count | Should -Be 1
            @($findings[0].EvidenceUris).Count | Should -Be 2
            @($findings[1].BaselineTags) | Should -Contain 'AuthScheme-PAT'
            @($findings[1].BaselineTags) | Should -Contain 'Connection-Shared'
            @($findings[0].EntityRefs).Count | Should -Be 3
            $findings[0].ToolVersion | Should -Be 'ado-rest-api-7.1'
        }

        It 'normalizes PAT and auth mechanism values' {
            $findings[1].AuthScheme | Should -Be 'PAT'
            $findings[1].AuthMechanism | Should -Be 'PAT'
            $findings[0].AuthMechanism | Should -Be 'WorkloadIdentityFederation'
        }
    }
}

