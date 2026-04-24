#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-KubeBench.ps1'
}

Describe 'Invoke-KubeBench: error paths' {
    Context 'when kubectl is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'kubectl' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'sets Source to kube-bench' {
            $result.Source | Should -Be 'kube-bench'
        }
    }
}

Describe 'Invoke-KubeBench: kubeconfig param surface (#240)' {
    BeforeAll {
        $script:Fixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'kubeconfig-mock.yaml'
    }

    It 'declares -KubeconfigPath, -KubeContext, -Namespace parameters' {
        $cmd = Get-Command -Name $script:Wrapper
        $cmd.Parameters.Keys | Should -Contain 'KubeconfigPath'
        $cmd.Parameters.Keys | Should -Contain 'KubeContext'
        $cmd.Parameters.Keys | Should -Contain 'Namespace'
        $cmd.Parameters.Keys | Should -Contain 'KubeBenchImage'
    }

    It 'defaults Namespace to "kube-system"' {
        $cmd = Get-Command -Name $script:Wrapper
        $defaultNs = $cmd.ScriptBlock.Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Namespace' } |
            ForEach-Object { $_.DefaultValue.Extent.Text.Trim("'") }
        $defaultNs | Should -Be 'kube-system'
    }

    It 'rejects a non-existent kubeconfig path with Failed envelope' {
        $bogus = Join-Path ([System.IO.Path]::GetTempPath()) "kb-doesnotexist-$([guid]::NewGuid()).yaml"
        $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -KubeconfigPath $bogus
        $result.Status | Should -Be 'Failed'
        $result.Source | Should -Be 'kube-bench'
        $result.Message | Should -Match 'wrapper:kube-bench.*NotFound.*does not exist'
    }

    It 'rejects URL-style kubeconfig values with Failed envelope' {
        $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' -KubeconfigPath 'https://example.invalid/kc'
        $result.Status | Should -Be 'Failed'
        $result.Source | Should -Be 'kube-bench'
        $result.Message | Should -Match 'wrapper:kube-bench.*InvalidParameter.*URLs are not accepted'
    }

    It 'defaults KubeBenchImage to a tagged aquasec image' {
        $cmd = Get-Command -Name $script:Wrapper
        $defaultImage = $cmd.ScriptBlock.Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'KubeBenchImage' } |
            ForEach-Object { $_.DefaultValue.Extent.Text.Trim("'") }
        $defaultImage | Should -Be 'aquasec/kube-bench:v0.7.2'
    }
}


Describe 'Invoke-KubeBench: KubeAuthMode param surface (#241/#242)' {
    BeforeAll {
        $script:Fixture = Join-Path $script:RepoRoot 'tests' 'fixtures' 'kubeconfig-mock.yaml'
    }

    It 'declares the KubeAuthMode + sub-params' {
        $cmd = Get-Command -Name $script:Wrapper
        foreach ($p in 'KubeAuthMode','KubeloginServerId','KubeloginClientId','KubeloginTenantId','WorkloadIdentityClientId','WorkloadIdentityTenantId','WorkloadIdentityServiceAccountToken') {
            $cmd.Parameters.Keys | Should -Contain $p
        }
    }

    It 'KubeAuthMode default value is "Default"' {
        $cmd = Get-Command -Name $script:Wrapper
        $defaultMode = $cmd.ScriptBlock.Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'KubeAuthMode' } |
            ForEach-Object { $_.DefaultValue.Extent.Text.Trim("'") }
        $defaultMode | Should -Be 'Default'
    }

    It 'rejects KubeloginClientId without KubeloginTenantId (offline param surface)' {
        Mock Get-Command { return [pscustomobject]@{ Name = 'kubelogin' } } -ParameterFilter { $Name -eq 'kubelogin' }
        Mock Get-Command { return [pscustomobject]@{ Name = 'kubebench' } } -ParameterFilter { $Name -eq 'kubebench' }
        $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' `
              -KubeconfigPath $script:Fixture -KubeAuthMode 'Kubelogin' `
              -KubeloginClientId '11111111-1111-1111-1111-111111111111'
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'together'
    }

    It 'rejects KubeAuthMode=WorkloadIdentity when sub-params are absent' {
        Mock Get-Command { return [pscustomobject]@{ Name = 'kubelogin' } } -ParameterFilter { $Name -eq 'kubelogin' }
        Mock Get-Command { return [pscustomobject]@{ Name = 'kubebench' } } -ParameterFilter { $Name -eq 'kubebench' }
        $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000' `
              -KubeconfigPath $script:Fixture -KubeAuthMode 'WorkloadIdentity'
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'WorkloadIdentity.*requires'
    }
}
