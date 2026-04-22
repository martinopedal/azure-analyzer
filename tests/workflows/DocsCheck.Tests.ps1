#Requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'docs-check.yml'
    $script:RawYaml = Get-Content -Raw -Path $script:WorkflowPath
}

Describe 'docs-check.yml documentation paths contract' {
    It 'treats docs/design as documentation for docs-required gate' {
        $script:RawYaml | Should -Match '\^docs\\/design\\/'
    }

    It 'mentions docs/design in the missing-docs guidance message' {
        $script:RawYaml | Should -Match 'architecture, design'
    }
}
