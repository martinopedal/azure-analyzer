#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Falco.ps1'
}

Describe 'Invoke-Falco: error paths' {
    Context 'when Az.ResourceGraph module is missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped or Failed' {
            $result.Status | Should -BeIn @('Skipped', 'Failed')
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about module or dependency' {
            $result.Message | Should -Not -BeNullOrEmpty
        }

        It 'sets Source to falco' {
            $result.Source | Should -Be 'falco'
        }
    }
}
