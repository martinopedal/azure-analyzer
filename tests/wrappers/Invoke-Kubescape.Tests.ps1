#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Kubescape.ps1'
}

Describe 'Invoke-Kubescape: error paths' {
    Context 'when kubescape CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'kubescape' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about kubescape not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to kubescape' {
            $result.Source | Should -Be 'kubescape'
        }
    }
}

Describe 'Invoke-Kubescape: kubeconfig param surface (#240)' {
    BeforeAll {
        $script:Fixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'kubeconfig-mock.yaml'
    }

    It 'declares -KubeconfigPath, -KubeContext, -Namespace parameters' {
        $cmd = Get-Command -Name $script:Wrapper
        $cmd.Parameters.Keys | Should -Contain 'KubeconfigPath'
        $cmd.Parameters.Keys | Should -Contain 'KubeContext'
        $cmd.Parameters.Keys | Should -Contain 'Namespace'
    }

    It 'rejects a non-existent kubeconfig path with a clear error' {
        $bogus = Join-Path ([System.IO.Path]::GetTempPath()) "kubescape-doesnotexist-$([guid]::NewGuid()).yaml"
        { & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -KubeconfigPath $bogus } |
            Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'rejects URL-style kubeconfig values (no remote fetch)' {
        { & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -KubeconfigPath 'https://example.invalid/kubeconfig' } |
            Should -Throw -ExpectedMessage '*URLs are not accepted*'
    }

    It 'accepts an existing kubeconfig file (skips on missing kubectl, no AKS discovery)' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'kubectl' }
        Mock Get-Command { return [pscustomobject]@{ Name = 'kubescape' } } -ParameterFilter { $Name -eq 'kubescape' }
        $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' `
            -KubeconfigPath $script:Fixture -KubeContext 'mock-ctx' -Namespace 'default'
        $result.Status | Should -Be 'Skipped'
        $result.Source | Should -Be 'kubescape'
    }
}

