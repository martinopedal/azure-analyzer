#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-ADOServiceConnections.ps1'
}

Describe 'Invoke-ADOServiceConnections: error paths' {
    Context 'when ADO PAT is missing' {
        BeforeAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\AZURE_DEVOPS_EXT_PAT -ErrorAction SilentlyContinue
            Remove-Item Env:\AZ_DEVOPS_PAT -ErrorAction SilentlyContinue
            $result = & $script:Wrapper -AdoOrg 'testorg'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about missing PAT' {
            $result.Message | Should -Match 'No ADO PAT'
        }
    }

    Context 'when ADO API call fails' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest { throw 'API call failed' }
            $result = & $script:Wrapper -AdoOrg 'testorg'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes error message' {
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }

    Context 'when ADO API returns garbage' {
        BeforeAll {
            $env:ADO_PAT_TOKEN = 'fake-token'
            Mock Invoke-WebRequest { [PSCustomObject]@{ Content = 'not json at all' } }
            $result = & $script:Wrapper -AdoOrg 'testorg'
        }

        AfterAll {
            Remove-Item Env:\ADO_PAT_TOKEN -ErrorAction SilentlyContinue
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }
    }
}

