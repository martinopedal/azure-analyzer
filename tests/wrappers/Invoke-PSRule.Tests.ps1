#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-PSRule.ps1'
}

Describe 'Invoke-PSRule: error paths' {
    Context 'when PSRule modules are missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about PSRule not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to psrule' {
            $result.Source | Should -Be 'psrule'
        }
    }
}

