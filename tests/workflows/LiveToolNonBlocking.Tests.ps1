#Requires -Version 7.4
<#
Regression guard for #861. The `live-tool-tests` job in
`.github/workflows/ci.yml` is tagged non-blocking (`continue-on-error: true`
at job level) but prior to this fix the Pester test step's
`Write-Error`/`exit 1` still rendered the job as failed on the PR checks
page. Step-level `continue-on-error: true` is required on the live-binary
install step AND the Pester step so the JOB itself reports green when only
non-blocking LiveTool assertions fail.
#>

BeforeAll {
    $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci.yml'
    $script:WorkflowText = Get-Content -Raw $script:WorkflowPath
}

Describe 'live-tool-tests step-level continue-on-error (regression for #861)' {
    It 'ci.yml exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'keeps job-level continue-on-error on live-tool-tests' {
        # Belt-and-braces: step-level fix is the primary guard, but job-level
        # stays to cover any future step that forgets its own flag.
        $script:WorkflowText | Should -Match '(?ms)live-tool-tests:.*?\n\s+continue-on-error:\s+true'
    }

    It 'sets continue-on-error: true on the "Install LiveTool CLI dependencies" step' {
        # Match step header, then any non-"- name:" content, then continue-on-error.
        $script:WorkflowText | Should -Match '(?ms)- name:\s+Install LiveTool CLI dependencies from install manifest \(Linux\)(?:(?!- name:).)*?\n\s+continue-on-error:\s+true'
    }

    It 'sets continue-on-error: true on the "Run LiveTool wrapper tests" step' {
        $script:WorkflowText | Should -Match '(?ms)- name:\s+Run LiveTool wrapper tests(?:(?!- name:).)*?\n\s+continue-on-error:\s+true'
    }

    It 'does not remove the Pester failure-count guard inside the step' {
        # We still want the step to Write-Error on failure so logs remain
        # actionable -- only the JOB status rendering changes.
        $script:WorkflowText | Should -Match 'LiveTool failures detected'
    }
}
