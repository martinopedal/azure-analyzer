#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Describe 'Invoke-Falco: kubeconfig param surface (#240)' {
    BeforeAll {
        $script:Fixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'kubeconfig-mock.yaml'
    }

    It 'declares -KubeconfigPath, -KubeContext, -Namespace parameters' {
        $cmd = Get-Command -Name $script:Wrapper
        $cmd.Parameters.Keys | Should -Contain 'KubeconfigPath'
        $cmd.Parameters.Keys | Should -Contain 'KubeContext'
        $cmd.Parameters.Keys | Should -Contain 'Namespace'
    }

    It 'defaults Namespace to "falco"' {
        $cmd = Get-Command -Name $script:Wrapper
        $defaultNs = $cmd.ScriptBlock.Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Namespace' } |
            ForEach-Object { $_.DefaultValue.Extent.Text.Trim("'") }
        $defaultNs | Should -Be 'falco'
    }

    It 'rejects a non-existent kubeconfig path' {
        $bogus = Join-Path ([System.IO.Path]::GetTempPath()) "falco-doesnotexist-$([guid]::NewGuid()).yaml"
        { & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -KubeconfigPath $bogus } |
            Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'rejects URL-style kubeconfig values' {
        { & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -KubeconfigPath 'https://example.invalid/kc' } |
            Should -Throw -ExpectedMessage '*URLs are not accepted*'
    }

    It 'accepts an existing kubeconfig in install mode (skips on missing helm, no AKS discovery)' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'helm' }
        $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' `
            -InstallFalco -KubeconfigPath $script:Fixture -KubeContext 'mock-ctx' -Namespace 'falco-ns'
        $result.Status | Should -Be 'Skipped'
        $result.Message | Should -Match 'helm is not installed'
    }
}


