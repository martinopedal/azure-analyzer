#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Retry.ps1')
    . (Join-Path $repoRoot 'modules\iac\IaCAdapters.ps1')
}

Describe 'IaCAdapters' {
    Context 'Invoke-IaCAdapter parameter validation' {
        It 'rejects unsupported flavour' {
            { Invoke-IaCAdapter -Flavour 'pulumi' -RepoPath '.' } | Should -Throw
        }

        It 'accepts bicep flavour' {
            # Will return Success/Skipped depending on CLI availability
            $result = Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $PSScriptRoot
            $result.Source | Should -Be 'bicep-iac'
        }

        It 'accepts terraform flavour' {
            $result = Invoke-IaCAdapter -Flavour 'terraform' -RepoPath $PSScriptRoot
            $result.Source | Should -Be 'terraform-iac'
        }
    }

    Context 'missing path handling' {
        It 'returns Skipped when no RepoPath or RemoteUrl is provided' {
            $result = Invoke-IaCAdapter -Flavour 'bicep'
            $result.Status | Should -Be 'Skipped'
            $result.Message | Should -Match 'No -RepoPath'
        }
    }

    Context 'sanitize behaviour' {
        It 'Remove-Credentials is available' {
            Get-Command Remove-Credentials -ErrorAction SilentlyContinue | Should -Not -BeNull
        }
    }

    Context 'Bicep validation with no .bicep files' {
        It 'returns Success with no findings when no .bicep files exist' {
            $result = Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $PSScriptRoot
            $result.Status | Should -Be 'Success'
            $result.Message | Should -Match 'No .bicep files'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'Terraform validation with no .tf files' {
        It 'returns Success with no findings when no .tf files exist' {
            $result = Invoke-IaCAdapter -Flavour 'terraform' -RepoPath $PSScriptRoot
            $result.Status | Should -Be 'Success'
            $result.Message | Should -Match 'No .tf files'
            @($result.Findings).Count | Should -Be 0
        }
    }

    Context 'result envelope shape' {
        It 'bicep adapter returns standard envelope fields' {
            $result = Invoke-IaCAdapter -Flavour 'bicep' -RepoPath $PSScriptRoot
            $result.PSObject.Properties['Source'] | Should -Not -BeNull
            $result.PSObject.Properties['Status'] | Should -Not -BeNull
            $result.PSObject.Properties['Findings'] | Should -Not -BeNull
        }

        It 'terraform adapter returns standard envelope fields' {
            $result = Invoke-IaCAdapter -Flavour 'terraform' -RepoPath $PSScriptRoot
            $result.PSObject.Properties['Source'] | Should -Not -BeNull
            $result.PSObject.Properties['Status'] | Should -Not -BeNull
            $result.PSObject.Properties['Findings'] | Should -Not -BeNull
        }
    }
}
