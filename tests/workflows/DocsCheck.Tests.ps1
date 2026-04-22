Describe 'Docs Check workflow' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'docs-check.yml'
        $script:WorkflowText = Get-Content $script:WorkflowPath -Raw
    }

    It 'exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'treats every docs/ path as documentation' {
        $script:WorkflowText | Should -Match '/\^docs\\\//'
    }

    It 'does not require hardcoded docs subdirectory allow-lists' {
        $script:WorkflowText | Should -Not -Match '/\^docs\\\/consumer\\\//'
        $script:WorkflowText | Should -Not -Match '/\^docs\\\/contributor\\\//'
    }
}
