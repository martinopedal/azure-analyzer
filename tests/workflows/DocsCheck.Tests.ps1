Describe 'Docs Check workflow' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'docs-check.yml'
        $script:WorkflowText = Get-Content $script:WorkflowPath -Raw
    }

    It 'exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'treats every docs/ path as documentation' {
        $script:WorkflowText.Contains('const docPathPatterns = [') | Should -BeTrue
        $script:WorkflowText.Contains('/^docs\//,') | Should -BeTrue
    }

    It 'does not require hardcoded docs subdirectory allow-lists' {
        $script:WorkflowText.Contains('docs/consumer/') | Should -BeFalse
        $script:WorkflowText.Contains('docs/contributor/') | Should -BeFalse
    }
}
