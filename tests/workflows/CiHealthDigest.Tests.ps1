Describe 'CI Health Digest regression guards' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-health-digest.yml'
        $script:WorkflowRaw = Get-Content -Raw -Path $script:WorkflowPath
    }

    It 'correlates triaged runs from all ci-failure issues (open and closed)' {
        $script:WorkflowRaw | Should -Match 'gh\s+issue\s+list\s+--repo\s+\$repo\s+--label\s+ci-failure\s+--state\s+all'
        $script:WorkflowRaw | Should -Match '--limit\s+200\s+--json\s+number,body'
    }

    It 'harvests run URLs from ci-failure issue comments' {
        $script:WorkflowRaw | Should -Match 'gh\s+api\s+--paginate\s+--slurp\s+"repos/\$repo/issues/comments\?per_page=100&since=\$since"'
        $script:WorkflowRaw | Should -Match '\[regex\]::Matches\(\$comment\.body,\s*''https://github\\.com/\[\^/\\s\]\+/\[\^/\\s\]\+/actions/runs/\\d\+'''
    }
}
