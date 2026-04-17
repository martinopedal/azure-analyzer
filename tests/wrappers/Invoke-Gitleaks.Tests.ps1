#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Gitleaks.ps1'
}

Describe 'Invoke-Gitleaks: error paths' {
    Context 'when gitleaks CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'gitleaks' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about gitleaks not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to gitleaks' {
            $result.Source | Should -Be 'gitleaks'
        }
    }
}

