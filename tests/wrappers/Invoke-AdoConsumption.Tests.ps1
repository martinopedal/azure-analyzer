#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AdoConsumption.ps1'

    function New-TestHttpException {
        param([int]$StatusCode, [string]$Message)
        $ex = [System.Exception]::new($Message)
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $StatusCode }) -Force
        return $ex
    }
}

Describe 'Invoke-AdoConsumption' {
    BeforeEach {
        Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\AZURE_DEVOPS_EXT_PAT -ErrorAction SilentlyContinue
        Remove-Item Env:\AZ_DEVOPS_PAT -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Variable -Name ProjectsAttempts -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'when PAT is missing' {
        It 'returns Skipped' {
            $result = & $script:Wrapper -Organization 'contoso'
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'consumption findings are emitted' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest {
                if ($Uri -match '_apis/projects') {
                    return [PSCustomObject]@{
                        Content = '{"value":[{"name":"payments"},{"name":"identity"}]}'
                        Headers = @{}
                    }
                }
                if ($Uri -match 'payments/_apis/build/builds') {
                    return [PSCustomObject]@{
                        Content = '{"value":[
                          {"id":1,"startTime":"2026-04-01T00:00:00Z","finishTime":"2026-04-01T00:50:00Z","result":"failed"},
                          {"id":2,"startTime":"2026-04-03T00:00:00Z","finishTime":"2026-04-03T00:40:00Z","result":"succeeded"},
                          {"id":3,"startTime":"2026-04-20T00:00:00Z","finishTime":"2026-04-20T01:20:00Z","result":"failed"},
                          {"id":4,"startTime":"2026-04-21T00:00:00Z","finishTime":"2026-04-21T01:10:00Z","result":"succeeded"}
                        ]}'
                        Headers = @{}
                    }
                }
                if ($Uri -match 'identity/_apis/build/builds') {
                    return [PSCustomObject]@{
                        Content = '{"value":[
                          {"id":10,"startTime":"2026-04-04T00:00:00Z","finishTime":"2026-04-04T00:15:00Z","result":"succeeded"},
                          {"id":11,"startTime":"2026-04-05T00:00:00Z","finishTime":"2026-04-05T00:12:00Z","result":"succeeded"}
                        ]}'
                        Headers = @{}
                    }
                }
                throw "Unexpected URI: $Uri"
            }
            $result = & $script:Wrapper -Organization 'contoso' -DaysBack 30
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Success' {
            $result.Status | Should -Be 'Success'
        }

        It 'flags high share project' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'ado.parallel-job-ratio' }).Count | Should -BeGreaterThan 0
        }

        It 'flags duration regression' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'ado.duration-regression' }).Count | Should -BeGreaterThan 0
        }

        It 'flags failed pipeline rate above threshold' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'ado.failed-pipeline-rate' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'retry and sanitization' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            $global:ProjectsAttempts = 0
            Mock Invoke-WebRequest {
                if ($Uri -match '_apis/projects') {
                    $global:ProjectsAttempts++
                    if ($global:ProjectsAttempts -eq 1) {
                        throw (New-TestHttpException -StatusCode 429 -Message 'Authorization: Basic c2VjcmV0')
                    }
                    return [PSCustomObject]@{ Content = '{"value":[]}'; Headers = @{} }
                }
                throw "Unexpected URI: $Uri"
            }
            $result = & $script:Wrapper -Organization 'contoso'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'retries after throttle and succeeds' {
            $result.Status | Should -Be 'Success'
            $global:ProjectsAttempts | Should -Be 2
        }

        It 'does not leak PAT markers in message' {
            $result.Message | Should -Not -Match 'Basic c2VjcmV0'
        }
    }
}
