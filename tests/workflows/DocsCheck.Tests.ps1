Describe 'Docs Check workflow' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'docs-check.yml'
        $script:WorkflowText = Get-Content $script:WorkflowPath -Raw
    }

    It 'exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'treats every docs/ path as documentation' {
        $script:WorkflowText | Should -Match ([regex]::Escape('/^docs\//'))
    }

    It 'does not require hardcoded docs subdirectory allow-lists' {
        $script:WorkflowText | Should -Not -Match ([regex]::Escape('/^docs\/consumer\//'))
        $script:WorkflowText | Should -Not -Match ([regex]::Escape('/^docs\/contributor\//'))
    }
}
