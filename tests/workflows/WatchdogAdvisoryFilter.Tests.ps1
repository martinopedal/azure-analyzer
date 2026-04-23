#Requires -Version 7.4
<#
Asserts that ci-failure-watchdog.yml filters out advisory workflows (CI / E2E /
Scheduled scan) from opening ci-failure issues. These workflows are monitored
for observability but their failures do not escalate to backlog noise because
they are NOT required branch-protection checks.

Required checks (Analyze, links, lint) still escalate via the watchdog.

Regression guard for Track A of `.squad/decisions/inbox/rca-drift-sonnet.md`.
#>

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:WatchdogPath = Join-Path $script:RepoRoot '.github' 'workflows' 'ci-failure-watchdog.yml'
    if (-not (Test-Path $script:WatchdogPath)) {
        throw "Watchdog workflow missing at $script:WatchdogPath"
    }
    $script:WatchdogContent = Get-Content -Raw $script:WatchdogPath
}

Describe 'Watchdog advisory-workflow filter' {
    It 'contains case statement for advisory workflow filter' {
        $script:WatchdogContent | Should -Match 'case\s+"\$WORKFLOW_NAME"\s+in'
    }

    It 'filters CI workflow as advisory' {
        $script:WatchdogContent | Should -Match '"CI"\|'
    }

    It 'filters E2E workflow as advisory' {
        $script:WatchdogContent | Should -Match '"E2E"\|'
    }

    It 'filters Scheduled scan workflow as advisory' {
        $script:WatchdogContent | Should -Match '"Scheduled scan"\)'
    }

    It 'exits 0 for advisory workflows (no issue creation)' {
        # The case block should contain "exit 0" to skip issue creation
        $script:WatchdogContent | Should -Match 'Advisory workflow.*failed.*logged but no issue created'
        $script:WatchdogContent | Should -Match 'exit 0'
    }

    It 'documents advisory filter with comment' {
        $script:WatchdogContent | Should -Match '# Advisory-workflow filter'
        $script:WatchdogContent | Should -Match 'NOT open ci-failure issues'
    }
}
