#Requires -Version 7.0

Describe 'CI failure watchdog SIGPIPE hardening' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-failure-watchdog.yml'
        $script:WorkflowText = Get-Content -Raw -LiteralPath $script:WorkflowPath
    }

    It 'uses here-strings for watchdog log truncation and grep extraction' {
        $script:WorkflowText | Should -Match 'head -n 500 <<<\s*"\$failed_log_raw"'
        $script:WorkflowText | Should -Match 'grep -qE ''HTTP 403\|rate limit exceeded'' <<<\s*"\$failed_log_raw"'
        $script:WorkflowText | Should -Match '##\\\[error\\\]\|::error::'' <<<\s*"\$failed_log_head"'
        $script:WorkflowText | Should -Match 'error\|failed\|fatal\)\(:\|\[\[:space:\]\]\)'' <<<\s*"\$failed_log_head"'
        $script:WorkflowText | Should -Match 'Exception\|Traceback\|exit code \[1-9\]\|exited with code\)'' <<<\s*"\$failed_log_head"'
    }

    It 'does not use printf|head or printf|grep pipelines in the watchdog extractor path' {
        $script:WorkflowText | Should -Not -Match 'printf ''%s\\n'' "\$failed_log_raw" \| head -n 500'
        $script:WorkflowText | Should -Not -Match 'printf ''%s\\n'' "\$failed_log_head" \| grep -Eim1'
        $script:WorkflowText | Should -Not -Match 'printf ''%s'' "\$failed_log_raw" \| grep -q'
    }
}
