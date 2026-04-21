#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Powerpipe.ps1'
}

Describe 'Invoke-Powerpipe' {
    It 'declares SubscriptionId and optional Benchmark parameters' {
        $cmd = Get-Command -Name $script:Wrapper
        $cmd.Parameters.Keys | Should -Contain 'SubscriptionId'
        $cmd.Parameters.Keys | Should -Contain 'Benchmark'
    }

    Context 'when powerpipe is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'powerpipe' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns skipped envelope' {
            $result.Source | Should -Be 'powerpipe'
            $result.Status | Should -Be 'Skipped'
            @($result.Findings).Count | Should -Be 0
            $result.Message | Should -Match 'not installed'
        }
    }
}
