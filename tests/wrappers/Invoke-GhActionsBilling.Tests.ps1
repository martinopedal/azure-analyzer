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
                if ($Arguments[0] -eq '--version') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'gh version 2.79.0 (2026-04-01)' }
                }
                if ($endpoint -like 'orgs/contoso/settings/billing/actions*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '{"included_minutes":2000,"included_minutes_used":2600,"total_paid_minutes_used":500,"minutes_used_breakdown":{"UBUNTU":1500,"WINDOWS":900,"MACOS":700}}' }
                }
                if ($endpoint -like 'orgs/contoso/repos*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '[{"name":"api","owner":{"login":"contoso"}},{"name":"web","owner":{"login":"contoso"}}]' }
                }
                if ($endpoint -like 'repos/contoso/api/actions/runs*') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '{"workflow_runs":[{"id":1,"run_duration_ms":4200000,"html_url":"https://github.com/contoso/api/actions/runs/1","workflow_id":42,"path":".github/workflows/ci.yml","head_branch":"main","name":"CI on ubuntu-latest"},{"id":2,"run_duration_ms":1800000}]}' }
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
            @($result.Findings | Where-Object { $_.RuleId -eq 'GHA-PaidMinutesExceeded' }).Count | Should -Be 1
        }

        It 'emits top consumer findings' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'GHA-TopConsumer' }).Count | Should -BeGreaterThan 0
        }

        It 'emits duration anomaly finding' {
            @($result.Findings | Where-Object { $_.RuleId -eq 'GHA-RunAnomaly' }).Count | Should -Be 1
        }

        It 'adds Schema 2.2 ETL metadata' {
            @($result.Findings | Where-Object { $_.Pillar -ne 'Cost Optimization' }).Count | Should -Be 0
            @($result.Findings | Where-Object { [string]::IsNullOrWhiteSpace($_.Impact) }).Count | Should -Be 0
            @($result.Findings | Where-Object { $_.Effort -ne 'Low' }).Count | Should -Be 0
            @($result.Findings | Where-Object { [string]::IsNullOrWhiteSpace($_.DeepLinkUrl) }).Count | Should -Be 0
            @($result.Findings | Where-Object { $null -eq $_.ScoreDelta }).Count | Should -Be 0
            @($result.Findings | Where-Object { @($_.EvidenceUris).Count -eq 0 }).Count | Should -Be 0
            @($result.Findings | Where-Object { @($_.BaselineTags).Count -lt 2 }).Count | Should -Be 0
            @($result.Findings | Where-Object { @($_.EntityRefs).Count -eq 0 }).Count | Should -Be 0
            @($result.Findings | Where-Object { [string]::IsNullOrWhiteSpace($_.ToolVersion) }).Count | Should -Be 0
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
                if ($Arguments[0] -eq '--version') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'gh version 2.79.0 (2026-04-01)' }
                }
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
