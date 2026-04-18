#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-ADOPipelineSecurity.ps1'
}

Describe 'Invoke-ADOPipelineSecurity' {
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
    }

    Context 'when the project has no matching ADO data yet' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest {
                [PSCustomObject]@{
                    Content = '{"count":0,"value":[]}'
                    Headers = @{}
                }
            }
            $result = & $script:Wrapper -AdoOrg 'testorg' -AdoProject 'empty-project'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Success with no findings' {
            $result.Status | Should -Be 'Success'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'when ADO returns pipeline metadata' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest {
                param([string]$Uri)

                $body = switch -Regex ($Uri) {
                    '_apis/build/definitions' {
                        @{
                            count = 2
                            value = @(
                                @{
                                    id = 101
                                    name = 'payments-prod'
                                    repository = @{ defaultBranch = 'refs/heads/main' }
                                    triggers = @(@{ triggerType = 'continuousIntegration'; branchFilters = @() })
                                    variableGroups = @(@{ id = 15; name = 'prod-shared' })
                                    process = @{
                                        phases = @(
                                            @{
                                                steps = @(
                                                    @{ inputs = @{ ConnectedServiceNameARM = 'Azure-Prod' } }
                                                )
                                            }
                                        )
                                    }
                                },
                                @{
                                    id = 102
                                    name = 'ops-prod'
                                    repository = @{ defaultBranch = 'refs/heads/main' }
                                    process = @{
                                        phases = @(
                                            @{
                                                steps = @(
                                                    @{ inputs = @{ azureSubscription = 'azure-prod' } }
                                                )
                                            }
                                        )
                                    }
                                }
                            )
                        } | ConvertTo-Json -Depth 20
                    }
                    '_apis/release/definitions' {
                        @{
                            count = 1
                            value = @(
                                @{
                                    id = 77
                                    name = 'Payments Release'
                                    environments = @(
                                        @{
                                            name = 'Production'
                                            preDeployApprovals = @{ approvals = @() }
                                            postDeployApprovals = @{ approvals = @() }
                                            deployPhases = @(
                                                @{
                                                    workflowTasks = @(
                                                        @{ inputs = @{ ConnectedServiceNameARM = 'Azure-Prod' } }
                                                    )
                                                }
                                            )
                                        }
                                    )
                                }
                            )
                        } | ConvertTo-Json -Depth 20
                    }
                    '_apis/distributedtask/variablegroups' {
                        @{
                            count = 1
                            value = @(
                                @{
                                    id = 15
                                    name = 'prod-shared'
                                    type = 'Vsts'
                                    variables = @{
                                        ApiToken = @{ isSecret = $false; value = 'super-secret' }
                                        Region = @{ isSecret = $false; value = 'westeurope' }
                                    }
                                }
                            )
                        } | ConvertTo-Json -Depth 20
                    }
                    '_apis/distributedtask/environments' {
                        @{
                            count = 1
                            value = @(
                                @{
                                    id = 9
                                    name = 'prod-eastus'
                                }
                            )
                        } | ConvertTo-Json -Depth 20
                    }
                    '_apis/pipelines/checks/configurations' {
                        '{"count":0,"value":[]}'
                    }
                    default {
                        throw "Unexpected URI: $Uri"
                    }
                }

                [PSCustomObject]@{
                    Content = $body
                    Headers = @{}
                }
            }

            $result = & $script:Wrapper -AdoOrg 'contoso' -AdoProject 'payments'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Status = Success' {
            $result.Status | Should -Be 'Success'
        }

        It 'produces findings across the expected ADO surfaces' {
            @($result.Findings).Count | Should -BeGreaterThan 3
            @($result.Findings.Category | Select-Object -Unique) | Should -Contain 'Pipeline Definition'
            @($result.Findings.Category | Select-Object -Unique) | Should -Contain 'Release Definition'
            @($result.Findings.Category | Select-Object -Unique) | Should -Contain 'Variable Group'
            @($result.Findings.Category | Select-Object -Unique) | Should -Contain 'Environment'
            @($result.Findings.Category | Select-Object -Unique) | Should -Contain 'Service Connection Usage'
        }

        It 'does not leak plaintext variable values into details' {
            ($result.Findings.Detail -join ' ') | Should -Not -Match 'super-secret'
        }
    }

    Context 'when an ADO API call fails' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest { throw 'API call failed' }
            $result = & $script:Wrapper -AdoOrg 'testorg' -AdoProject 'payments'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }
    }
}
