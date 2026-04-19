#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-IaCBicep.ps1'
}

Describe 'Invoke-IaCBicep: error paths' {
    Context 'when bicep CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'bicep' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about bicep not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to bicep-iac' {
            $result.Source | Should -Be 'bicep-iac'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when repository path does not exist' {
        BeforeAll {
            Mock Get-Command { return @{ Name = 'bicep' } } -ParameterFilter { $Name -eq 'bicep' }
            $result = & $script:Wrapper -RepoPath 'C:\nonexistent\path\that\does\not\exist'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'sets Source to bicep-iac' {
            $result.Source | Should -Be 'bicep-iac'
        }
    }
}
