#Requires -Version 7.0
<#
Regression guard for #862. The `ci-failure-watchdog.yml` `triage-failure` job
MUST key its concurrency group off `github.event.workflow_run.id` (or another
per-triggering-run identifier). A constant group name causes GitHub to cancel
queued runs when a third run arrives (only one running + one pending allowed
per group, regardless of `cancel-in-progress`). The triage step is already
hash-idempotent, so parallel runs are safe.

Before this fix, 23 of 32 recent watchdog runs were cancelled.
#>

BeforeAll {
    $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-failure-watchdog.yml'
    $script:WorkflowText = Get-Content -Raw $script:WorkflowPath
}

Describe 'CI failure watchdog concurrency (regression for #862)' {
    It 'workflow file exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'declares a triage-failure job concurrency block' {
        $script:WorkflowText | Should -Match '(?ms)triage-failure:.*?\n\s+concurrency:'
    }

    It 'keys the concurrency group on workflow_run.id (no constant group)' {
        # The group expression must reference workflow_run.id so each
        # triggering run gets its own slot. A constant group like
        # `group: ci-failure-watchdog\n` (no interpolation) is the regression.
        $script:WorkflowText | Should -Match 'group:\s+ci-failure-watchdog-\$\{\{\s*github\.event\.workflow_run\.id\s*\}\}'
    }

    It 'does NOT use a constant `ci-failure-watchdog` group without suffix' {
        # Guard against someone re-introducing the self-cancelling constant.
        $script:WorkflowText | Should -Not -Match '(?m)^\s+group:\s+ci-failure-watchdog\s*$'
    }

    It 'keeps cancel-in-progress: false to preserve triage per run' {
        $script:WorkflowText | Should -Match '(?ms)group:\s+ci-failure-watchdog-\$\{\{\s*github\.event\.workflow_run\.id\s*\}\}\s*\r?\n\s+cancel-in-progress:\s+false'
    }
}
