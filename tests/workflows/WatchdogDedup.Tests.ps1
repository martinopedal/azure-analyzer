#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'CI Failure Watchdog Dedup Logic' {
    BeforeAll {
        $workflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci-failure-watchdog.yml'
        if (-not (Test-Path $workflowPath)) {
            throw "ci-failure-watchdog.yml not found at $workflowPath"
        }
        $workflowContent = Get-Content $workflowPath -Raw
    }

    Context 'Pre-create reconciliation' {
        It 'queries for existing open issues before creating new issue' {
            # The fix (E3) must query for existing OPEN issues before attempting create
            $workflowContent | Should -Match 'existing_issue_records.*gh issue list.*--state all.*--search.*error_hash'
            $workflowContent | Should -Match 'select\(.state == "OPEN"\)'
        }

        It 'comments on existing open issue instead of creating duplicate' {
            # If existing open issue found, comment on it
            $workflowContent | Should -Match 'if \[ -n "\$existing_issue" \]; then'
            $workflowContent | Should -Match 'gh issue comment.*still failing'
        }

        It 'creates new issue only if no existing open issue found' {
            # New issue creation happens only in the else block
            $workflowContent | Should -Match 'else[\s\S]{0,200}?gh_with_retry gh issue create'
        }
    }

    Context 'Exponential backoff retry' {
        It 'wraps gh issue create with retry loop' {
            # The fix (E3) must wrap gh issue create in a retry loop with exponential backoff
            $workflowContent | Should -Match 'retry_attempt=0'
            $workflowContent | Should -Match 'max_retries=\d+'
            $workflowContent | Should -Match 'while \[ \$retry_attempt -le \$max_retries \]'
        }

        It 'uses exponential backoff sleep between retries' {
            # Exponential backoff: sleep_time = 2^retry_attempt
            $workflowContent | Should -Match 'sleep_time=\$\(\(2 \*\* retry_attempt\)\)'
            $workflowContent | Should -Match 'sleep "\$sleep_time"'
        }

        It 'wraps gh issue comment with retry for transient failures' {
            # Comment calls also need retry - check that gh_with_retry is called for both create and comment
            $createCalls = [regex]::Matches($workflowContent, 'gh_with_retry gh issue create')
            $commentCalls = [regex]::Matches($workflowContent, 'gh_with_retry gh issue comment')
            ($createCalls.Count + $commentCalls.Count) | Should -BeGreaterOrEqual 2 -Because 'Both create and comment need retry'
        }
    }

    Context 'Race reconciliation fallback' {
        It 'reconciles if create fails after all retries' {
            # If create fails after max retries, reconcile by re-querying and commenting
            $workflowContent | Should -Match 'if \[ "\$issue_created" = false \]; then'
            $workflowContent | Should -Match 'reconciling for hash'
            $workflowContent | Should -Match 'reconciled after create race'
        }

        It 'exits with error only if create AND reconcile both fail' {
            # Final fallback: if create fails and reconcile finds nothing, exit 1
            $workflowContent | Should -Match 'Failed to create or reconcile ci-failure issue'
            $workflowContent | Should -Match 'exit 1'
        }
    }

    Context 'Dedup hash integrity' {
        It 'uses workflow name and first error line for hash input' {
            # Hash input must be workflow name + first error line
            $workflowContent | Should -Match 'hash_input="\$\{WORKFLOW_NAME\}\|\$\{first_error_line\}"'
            $workflowContent | Should -Match 'error_hash=.*sha256sum'
        }

        It 'searches for issues by hash in title' {
            # All queries use [error_hash] in:title to find duplicates
            $workflowContent | Should -Match '\[(\$\{)?error_hash(\})?\] in:title'
        }
    }

    Context 'Post-create dedup sweep (legacy behavior preserved)' {
        It 'still runs post-create dedup sweep for belt-and-suspenders' {
            # The post-create sweep is kept as a safety net
            $workflowContent | Should -Match 'mapfile -t matching_issues'
            $workflowContent | Should -Match 'Closing duplicate ci-failure issue in favor of'
        }
    }
}
