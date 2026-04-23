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
        # After PR #941, the workflow uses /^docs\// to match all docs subdirectories
        # instead of listing each one individually (e.g. /^docs\/design\/)
        $script:RawYaml | Should -Match '/\^docs\\/'
    }

    It 'mentions docs/ in the missing-docs guidance message' {
        $script:RawYaml | Should -Match 'docs/'
    }
}
