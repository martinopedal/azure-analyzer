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

    It 'does not contain duplicated extractor blocks from a botched merge (#748)' {
        # Each canonical extractor statement must appear exactly once -- a duplicate
        # signals an unresolved merge that breaks the bash parser at runtime and
        # silently disables per-failure triage (root cause of the 52-failure backlog
        # surfaced by ci-health-digest in issue #748).
        $rateLimitMatches  = [regex]::Matches($script:WorkflowText, [regex]::Escape("if grep -qE 'HTTP 403|rate limit exceeded' <<< ""`$failed_log_raw"""))
        $headTruncMatches  = [regex]::Matches($script:WorkflowText, [regex]::Escape('failed_log_head="$(head -n 500 <<< "$failed_log_raw")"'))
        $sanitizeMatches   = [regex]::Matches($script:WorkflowText, [regex]::Escape('first_error_line="$(sanitize_text "$first_error_line")"'))
        $rateLimitMatches.Count | Should -Be 1
        $headTruncMatches.Count | Should -Be 1
        $sanitizeMatches.Count  | Should -Be 1
    }

    It 'has no broken non-extended grep regex with literal pipe (#748)' {
        # `grep -q 'a|b'` (without -E) treats the pipe literally and never matches,
        # which is exactly the bug that disabled rate-limit suppression on the watchdog.
        $script:WorkflowText | Should -Not -Match "grep -q 'HTTP 403\|rate limit exceeded'"
    }
}
