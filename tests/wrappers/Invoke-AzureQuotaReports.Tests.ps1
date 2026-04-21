#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AzureQuotaReports.ps1'
}

Describe 'Invoke-AzureQuotaReports' {
    BeforeEach {
        function global:az {
            [CmdletBinding()]
            param()
        }
        function global:Invoke-WithRetry {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][scriptblock] $ScriptBlock,
                [Nullable[int]] $MaxAttempts,
                [Nullable[int]] $InitialDelaySeconds,
                [Nullable[int]] $MaxDelaySeconds
            )
            & $ScriptBlock
        }
        function global:Invoke-WithTimeout {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string] $Command,
                [Parameter(Mandatory)][string[]] $Arguments,
                [int] $TimeoutSec = 300
            )

            $joined = ($Arguments -join ' ')
            if ($joined -like 'account list*') {
                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = '[{"id":"00000000-0000-0000-0000-000000000000","name":"sub-a","state":"Enabled"}]'
                }
            }
            if ($joined -like 'account set*') {
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }
            if ($joined -like 'account list-locations*') {
                return [PSCustomObject]@{ ExitCode = 0; Output = '["eastus"]' }
            }
            if ($joined -like 'vm list-usage*') {
                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = '[{"name":{"value":"standardDSv5Family","localizedValue":"Standard DSv5 Family"},"currentValue":90,"limit":100,"unit":"Count"}]'
                }
            }
            if ($joined -like 'network list-usages*') {
                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = '[{"name":{"value":"PublicIPAddresses","localizedValue":"Public IP Addresses"},"currentValue":5,"limit":10,"unit":"Count"}]'
                }
            }

            return [PSCustomObject]@{ ExitCode = 1; Output = "Unexpected command: $Command $joined" }
        }
    }

    AfterEach {
        foreach ($fn in @('az', 'Invoke-WithRetry', 'Invoke-WithTimeout')) {
            if (Test-Path "Function:global:$fn") {
                Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue
            }
        }
    }

    It 'emits quota findings with compliant threshold mapping' {
        $result = & $script:Wrapper -Threshold 80

        $result.Status | Should -Be 'Success'
        @($result.Findings).Count | Should -Be 2

        $vm = @($result.Findings | Where-Object { $_.Service -eq 'vm' })[0]
        $vm.Compliant | Should -BeFalse
        $vm.UsagePercent | Should -Be 90
        $vm.Pillar | Should -Be 'Reliability'
        $vm.Category | Should -Be 'Capacity'
        $vm.EntityType | Should -Be 'Subscription'

        $network = @($result.Findings | Where-Object { $_.Service -eq 'network' })[0]
        $network.Compliant | Should -BeTrue
        $network.UsagePercent | Should -Be 50
    }
}
