#Requires -Version 7.4

Describe 'PR auto-resolve threads workflow' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'pr-auto-resolve-threads.yml'
        $script:WorkflowText = Get-Content -Raw -LiteralPath $script:WorkflowPath
    }

    It 'exists' {
        Test-Path -LiteralPath $script:WorkflowPath | Should -BeTrue
    }

    It 'uses RESOLVE_THREADS_TOKEN as GH_TOKEN' {
        $script:WorkflowText | Should -Match '(?m)^\s*GH_TOKEN:\s*\$\{\{\s*secrets\.RESOLVE_THREADS_TOKEN\s*\}\}\s*$'
    }

    It 'fails when resolver token is missing' {
        $script:WorkflowText | Should -Match 'RESOLVE_THREADS_TOKEN secret is required for PR thread auto-resolution\.'
    }

    It 'does not soft-fail thread resolution anymore' {
        $script:WorkflowText | Should -Not -Match '(?ms)Resolve addressed review threads.*?continue-on-error:\s*true'
        $script:WorkflowText | Should -Not -Match 'treating as non-fatal'
        $script:WorkflowText | Should -Not -Match 'Auto-resolve failed:'
        $script:WorkflowText | Should -Not -Match 'Auto-resolve threw:'
    }
}
