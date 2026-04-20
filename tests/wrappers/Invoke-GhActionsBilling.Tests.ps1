#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-GhActionsBilling.ps1'
    function global:Invoke-WithTimeout {
        param([string]$Command, [string[]]$Arguments, [int]$TimeoutSec)
        [PSCustomObject]@{ ExitCode = 0; Output = '{}' }
    }
}

AfterAll {
    Remove-Item Function:\Invoke-WithTimeout -ErrorAction SilentlyContinue
    Remove-Variable -Name BillingAttempt -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-GhActionsBilling' {
    Context 'when gh is missing' {
        BeforeAll {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
            $result = & $script:Wrapper -Org 'contoso'
        }

        It 'returns Skipped' {
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'budget exceeded top consumers and anomalies' {
        BeforeAll {
            Mock Get-Command {
                if ($Name -eq 'gh') { return [PSCustomObject]@{ Name = 'gh' } }
                return $null
            }

            Mock Invoke-WithTimeout {
                $endpoint = $Arguments[1]
                if ($endpoint -like 'orgs/contoso/settings/billing/actions*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '{"included_minutes":2000,"included_minutes_used":2600,"total_paid_minutes_used":500}' }
                }
                if ($endpoint -like 'orgs/contoso/repos*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '[{"name":"api","owner":{"login":"contoso"}},{"name":"web","owner":{"login":"contoso"}}]' }
                }
                if ($endpoint -like 'repos/contoso/api/actions/runs*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '{"workflow_runs":[{"id":1,"run_duration_ms":4200000,"html_url":"https://github.com/contoso/api/actions/runs/1"},{"id":2,"run_duration_ms":1800000}]}' }
                }
                if ($endpoint -like 'repos/contoso/web/actions/runs*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '{"workflow_runs":[{"id":10,"run_duration_ms":1200000},{"id":11,"run_duration_ms":1500000}]}' }
                }
                throw "Unexpected endpoint: $endpoint"
            }

            $result = & $script:Wrapper -Org 'contoso'
        }

        It 'returns Success' {
            $result.Status | Should -Be 'Success'
        }

        It 'emits org over budget finding' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'gh-actions.org-over-budget' }).Count | Should -Be 1
        }

        It 'emits top consumer findings' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'gh-actions.top-consumer' }).Count | Should -BeGreaterThan 0
        }

        It 'emits duration anomaly finding' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'gh-actions.run-duration-anomaly' }).Count | Should -Be 1
        }
    }

    Context 'retries throttled gh api calls' {
        BeforeAll {
            Mock Get-Command {
                if ($Name -eq 'gh') { return [PSCustomObject]@{ Name = 'gh' } }
                return $null
            }

            $global:BillingAttempt = 0
            Mock Invoke-WithTimeout {
                $endpoint = $Arguments[1]
                if ($endpoint -like 'orgs/contoso/settings/billing/actions*') {
                    $global:BillingAttempt++
                    if ($global:BillingAttempt -eq 1) {
                        return [PSCustomObject]@{ ExitCode = 1; Output = 'HTTP 429 rate limit exceeded' }
                    }
                    return [PSCustomObject]@{ ExitCode = 0; Output = '{"included_minutes":2000,"included_minutes_used":1200,"total_paid_minutes_used":0}' }
                }
                if ($endpoint -like 'orgs/contoso/repos*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '[]' }
                }
                throw "Unexpected endpoint: $endpoint"
            }

            $result = & $script:Wrapper -Org 'contoso'
        }

        It 'succeeds after retry' {
            $result.Status | Should -Be 'Success'
            $global:BillingAttempt | Should -Be 2
        }
    }
}
