#Requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'docs-check.yml'
    $script:RawYaml = Get-Content -Raw -Path $script:WorkflowPath
}

Describe 'docs-check.yml documentation paths contract' {
    It 'treats docs/ subdirectories as documentation for docs-required gate' {
        $script:RawYaml | Should -Match '\^docs\\/'
    }

    It 'mentions copy-pasteable suggested CHANGELOG entry in error message' {
        $script:RawYaml | Should -Match 'Suggested:'
    }

    It 'lists auto-skip title prefixes in error message' {
        $script:RawYaml | Should -Match 'chore\(deps\):'
        $script:RawYaml | Should -Match 'Auto-skip title prefixes'
    }
}
