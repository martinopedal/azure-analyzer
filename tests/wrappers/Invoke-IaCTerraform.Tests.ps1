#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-IaCTerraform.ps1'
}

Describe 'Invoke-IaCTerraform: error paths' {
    Context 'when neither terraform nor trivy CLI is available' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'terraform' -or $Name -eq 'trivy' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about missing CLIs' {
            $result.Message | Should -Match 'terraform.*trivy|trivy.*terraform|Neither'
        }

        It 'sets Source to terraform-iac' {
            $result.Source | Should -Be 'terraform-iac'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when repository path does not exist' {
        BeforeAll {
            Mock Get-Command { return @{ Name = 'terraform' } } -ParameterFilter { $Name -eq 'terraform' }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'trivy' }
            $result = & $script:Wrapper -RepoPath 'C:\nonexistent\path\that\does\not\exist'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'sets Source to terraform-iac' {
            $result.Source | Should -Be 'terraform-iac'
        }
    }
}
