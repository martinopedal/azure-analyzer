Describe 'Docs Check workflow' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'docs-check.yml'
        $script:WorkflowText = Get-Content $script:WorkflowPath -Raw
    }

    It 'exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'treats every docs/ path as documentation' {
        $script:WorkflowText | Should -Match '\^docs\\/'
    }
}
