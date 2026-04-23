#Requires -Version 7.0

Describe 'CI failure watchdog SIGPIPE hardening' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-failure-watchdog.yml'
        $script:WorkflowText = Get-Content -Raw -LiteralPath $script:WorkflowPath
    }

    It 'uses here-strings for watchdog log truncation and grep extraction' {
        $script:WorkflowText | Should -Match 'failed_log_head="\$\(head -n 500 <<< "\$failed_log_raw"\)"'
        $script:WorkflowText | Should -Match 'grep -qE ''HTTP 403\|rate limit exceeded'' <<< "\$failed_log_raw"'
        $script:WorkflowText | Should -Match 'grep -Eim1 ''##\\\[error\\\]\|::error::'' <<< "\$failed_log_head"'
    }

    It 'does not use printf|head or printf|grep pipelines in the watchdog extractor path' {
        $script:WorkflowText | Should -Not -Match 'printf ''%s\\n'' "\$failed_log_raw" \| head -n 500'
        $script:WorkflowText | Should -Not -Match 'printf ''%s\\n'' "\$failed_log_head" \| grep -Eim1'
        $script:WorkflowText | Should -Not -Match 'printf ''%s'' "\$failed_log_raw" \| grep -q'
    }
}
