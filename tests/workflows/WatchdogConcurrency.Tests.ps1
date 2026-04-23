#Requires -Version 7.0
<#
Validates concurrency model for ci-failure-watchdog.yml. After PR #944, the
watchdog uses a schedule trigger (every 15 min) instead of workflow_run.
With schedule, a constant concurrency group is CORRECT and SAFE because:
1. The triage logic is hash-idempotent (SHA256 dedup prevents duplicate issues).
2. The 15-min interval keeps queue pressure low.
3. GitHub's default group behavior (one running + one pending) is sufficient.

This replaced the old #862 regression guard which required workflow_run.id
suffixes to prevent cascade cancellations when Copilot-actor triggered runs.
#>

BeforeAll {
    $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-failure-watchdog.yml'
    $script:WorkflowText = Get-Content -Raw $script:WorkflowPath
}

Describe 'CI failure watchdog concurrency (post-PR #944 schedule model)' {
    It 'workflow file exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'declares a triage-failure job concurrency block' {
        $script:WorkflowText | Should -Match '(?ms)triage-failure:.*?\n\s+concurrency:'
    }

    It 'uses a constant ci-failure-watchdog concurrency group (schedule-safe)' {
        # With schedule trigger + hash-idempotent triage, a constant group is
        # safe and correct. The 15-min interval + GitHub's queue model (1 run
        # + 1 pending) prevents runaway queues. This is the EXPECTED pattern.
        $script:WorkflowText | Should -Match '(?m)^\s+group:\s+ci-failure-watchdog\s*$'
    }

    It 'does NOT use workflow_run.id suffix (schedule trigger has no run context)' {
        # The schedule trigger does not provide github.event.workflow_run, so
        # the old per-run group suffix pattern is invalid for this trigger.
        $script:WorkflowText | Should -Not -Match 'workflow_run\.id'
    }

    It 'keeps cancel-in-progress: false to preserve any overlapping scans' {
        $script:WorkflowText | Should -Match '(?ms)group:\s+ci-failure-watchdog\s*\r?\n\s+cancel-in-progress:\s+false'
    }
}
