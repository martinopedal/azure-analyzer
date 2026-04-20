#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Infracost.ps1'
}

Describe 'Invoke-Infracost: error paths' {
    Context 'when infracost CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'infracost' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns Source = infracost' {
            $result.Source | Should -Be 'infracost'
        }

        It 'returns SchemaVersion 1.0' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when scan path does not exist' {
        BeforeAll {
            Mock Get-Command { return @{ Name = 'infracost' } } -ParameterFilter { $Name -eq 'infracost' }
            $result = & $script:Wrapper -Path 'C:\does-not-exist\infracost'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }
    }
}
