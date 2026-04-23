#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowPath = [IO.Path]::Combine($script:RepoRoot, '.github', 'workflows', 'closes-link-required.yml')
    $script:WorkflowText = if (Test-Path $script:WorkflowPath) { Get-Content $script:WorkflowPath -Raw } else { '' }
}

Describe 'closes-link-required workflow contract' {
    It 'workflow file exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'exempts trusted bot authors including Copilot app identities' {
        $script:WorkflowText | Should -Match 'dependabot\[bot\]'
        $script:WorkflowText | Should -Match 'copilot-swe-agent\[bot\]'
        $script:WorkflowText | Should -Match 'Copilot'
        $script:WorkflowText | Should -Match 'copilot'
    }

    It 'still supports skip-closes-check label bypass' {
        $script:WorkflowText | Should -Match 'skip-closes-check'
    }
}
