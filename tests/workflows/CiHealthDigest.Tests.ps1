Describe 'CI Health Digest regression guards' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-health-digest.yml'
        $script:WorkflowRaw = Get-Content -Raw -Path $script:WorkflowPath
    }

    It 'correlates triaged runs from all ci-failure issues (open and closed)' {
        $script:WorkflowRaw.Contains('gh issue list --repo $repo --label ci-failure --state all') | Should -BeTrue
    }

    It 'harvests run URLs from ci-failure issue comments' {
        $script:WorkflowRaw.Contains('gh issue view $i.number --repo $repo --comments --json comments') | Should -BeTrue
    }
}
