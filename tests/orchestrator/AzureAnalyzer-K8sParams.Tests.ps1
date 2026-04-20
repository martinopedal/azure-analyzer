#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here        = Split-Path $PSCommandPath -Parent
    $script:RepoRoot    = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Orchestrator = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
    $script:Fixture     = Join-Path $script:RepoRoot 'tests' 'fixtures' 'kubeconfig-mock.yaml'
}

Describe 'Invoke-AzureAnalyzer: K8s param surface (#240)' {
    It 'declares -KubeconfigPath, -KubeContext, and per-tool namespace params' {
        $cmd = Get-Command -Name $script:Orchestrator
        $cmd.Parameters.Keys | Should -Contain 'KubeconfigPath'
        $cmd.Parameters.Keys | Should -Contain 'KubeContext'
        $cmd.Parameters.Keys | Should -Contain 'KubescapeNamespace'
        $cmd.Parameters.Keys | Should -Contain 'FalcoNamespace'
        $cmd.Parameters.Keys | Should -Contain 'KubeBenchNamespace'
    }

    It 'kubeconfig fixture file is present (used by wrapper kubeconfig-mode tests)' {
        Test-Path -LiteralPath $script:Fixture | Should -BeTrue
    }

    It 'forwards K8s params to wrappers via the subscription dispatch block (source-level check)' {
        $src = Get-Content $script:Orchestrator -Raw
        $src | Should -Match "toolDef\.name -eq 'kubescape'"
        $src | Should -Match "toolDef\.name -eq 'kube-bench'"
        $src | Should -Match "toolDef\.name -eq 'falco'"
        $src | Should -Match 'params\[.KubeconfigPath.\]'
        $src | Should -Match 'params\[.KubeContext.\]'
        $src | Should -Match 'params\[.Namespace.\]\s*=\s*\$KubescapeNamespace'
        $src | Should -Match 'params\[.Namespace.\]\s*=\s*\$FalcoNamespace'
        $src | Should -Match 'params\[.Namespace.\]\s*=\s*\$KubeBenchNamespace'
    }

    It 'defaults FalcoNamespace=falco, KubeBenchNamespace=kube-system, KubescapeNamespace=empty' {
        $cmd = Get-Command -Name $script:Orchestrator
        $params = $cmd.ScriptBlock.Ast.ParamBlock.Parameters
        $get = {
            param($name)
            ($params | Where-Object { $_.Name.VariablePath.UserPath -eq $name } |
                ForEach-Object { $_.DefaultValue.Extent.Text.Trim("'") })
        }
        & $get 'FalcoNamespace'     | Should -Be 'falco'
        & $get 'KubeBenchNamespace' | Should -Be 'kube-system'
        # KubescapeNamespace default is the empty string ''
        $ksDefault = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'KubescapeNamespace' } |
            ForEach-Object { $_.DefaultValue.Extent.Text }
        $ksDefault | Should -Be "''"
    }
}
