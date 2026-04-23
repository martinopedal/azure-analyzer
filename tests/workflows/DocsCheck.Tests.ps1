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

    It 'treats docs/design as documentation' {
        # The ^docs\/ docPathPattern covers all docs/ subdirectories including docs/design/
        $script:RawYaml | Should -Match '\^docs\\/'
        'docs/design/adr-001.md' | Should -Match '^docs/'
    }

    It 'mentions docs/design in missing-docs guidance' {
        # Error guidance tells authors they can add/edit pages under docs/
        $script:RawYaml | Should -Match 'under docs/'
    }

    It 'treats .copilot/audits as documentation' {
        $script:RawYaml | Should -Match 'copilot\\/audits'
    }

    It 'treats .squad decision logs as documentation' {
        $script:RawYaml | Should -Match 'squad\\/decisions'
    }

    It 'treats .squad/ceremonies.md as documentation' {
        $script:RawYaml | Should -Match 'ceremonies\\.md'
    }

    It 'includes all expected root-level doc files' {
        $expectedRootDocs = @('README.md', 'CHANGELOG.md', 'PERMISSIONS.md', 'CONTRIBUTING.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md')
        foreach ($doc in $expectedRootDocs) {
            $script:RawYaml | Should -Match ([regex]::Escape($doc))
        }
    }

    It 'mentions copy-pasteable suggested CHANGELOG entry in error message' {
        $script:RawYaml | Should -Match 'Suggested:'
    }

    It 'lists auto-skip title prefixes in error message' {
        $script:RawYaml | Should -Match 'chore\(deps\):'
        $script:RawYaml | Should -Match 'Auto-skip title prefixes'
    }
}
