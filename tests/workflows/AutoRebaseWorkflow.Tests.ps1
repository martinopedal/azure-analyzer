#Requires -Version 7.4
<#
Invariant tests for .github/workflows/pr-auto-rebase.yml. Guards the contract
from repo directive 2026-04-22T23:35:00Z: triggers, permissions, helper-script
wiring, SHA-pinning, agent-branch filter, watchdog watchlist registration.
#>

BeforeAll {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Install-Module powershell-yaml -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop | Out-Null
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:WorkflowPath = Join-Path $script:WorkflowsDir 'pr-auto-rebase.yml'
    $script:WorkflowName = 'PR Auto-Rebase Conflicts'
    $script:HelperPath   = Join-Path $script:RepoRoot 'scripts' 'Resolve-CommonMergeConflicts.ps1'
}

Describe 'PR Auto-Rebase Conflicts workflow' {
    It 'exists at the canonical path' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'parses as valid YAML' {
        { ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath) } | Should -Not -Throw
    }

    It 'declares the canonical workflow name' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $parsed['name'] | Should -Be $script:WorkflowName
    }

    It 'triggers on push to main, pull_request synchronize/opened/reopened, and workflow_dispatch' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $onBlock = if ($parsed.ContainsKey('on')) { $parsed['on'] } else { $parsed[$true] }
        $onBlock.ContainsKey('push')              | Should -BeTrue
        $onBlock.ContainsKey('pull_request')      | Should -BeTrue
        $onBlock.ContainsKey('workflow_dispatch') | Should -BeTrue
        @($onBlock['push']['branches']) | Should -Contain 'main'
        foreach ($t in @('synchronize','opened','reopened')) {
            @($onBlock['pull_request']['types']) | Should -Contain $t
        }
    }

    It 'declares the required permissions (contents:write, pull-requests:write, actions:read)' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $perms = $parsed['permissions']
        $perms['contents']      | Should -Be 'write'
        $perms['pull-requests'] | Should -Be 'write'
        $perms['actions']       | Should -Be 'read'
    }

    It 'has a per-PR concurrency group with cancel-in-progress' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $parsed['concurrency']['group']              | Should -Match 'auto-rebase-pr-'
        $parsed['concurrency']['cancel-in-progress'] | Should -BeTrue
    }

    It 'invokes the helper script scripts/Resolve-CommonMergeConflicts.ps1' {
        Test-Path $script:HelperPath | Should -BeTrue
        $content = Get-Content -Raw $script:WorkflowPath
        $content | Should -Match 'Resolve-CommonMergeConflicts\.ps1'
    }

    It 'filters to agent-pushable branch prefixes (squad/copilot/fix/feat/ci/docs)' {
        $content = Get-Content -Raw $script:WorkflowPath
        foreach ($prefix in @('squad', 'copilot', 'fix', 'feat', 'ci', 'docs')) {
            $content | Should -Match $prefix
        }
    }

    It 'gates by allow-listed authors (no human-owned branch auto-rebase)' {
        $content = Get-Content -Raw $script:WorkflowPath
        foreach ($author in @('copilot-swe-agent\[bot\]','martinopedal','Copilot','github-actions\[bot\]','dependabot\[bot\]')) {
            $content | Should -Match $author
        }
    }

    It 'uses --force-with-lease and never plain --force on push' {
        $content = Get-Content -Raw $script:WorkflowPath
        $content | Should -Match '--force-with-lease'
        ($content -split "`n") | Where-Object { $_ -match '\bgit push\b.*--force(?!-with-lease)' } |
            Should -BeNullOrEmpty -Because 'plain --force is forbidden per the resilience contract'
    }

    It 'aborts the rebase and posts a PR comment when an unresolved file is detected' {
        $content = Get-Content -Raw $script:WorkflowPath
        $content | Should -Match 'rebase --abort'
        $content | Should -Match 'gh pr comment'
        $content | Should -Match 'Manual rebase required'
    }

    It 'SHA-pins every third-party uses: action (no tag-only refs)' {
        $content = Get-Content -Raw $script:WorkflowPath
        $usesLines = ($content -split "`n") | Where-Object { $_ -match '^\s*-?\s*uses:\s*' }
        foreach ($line in $usesLines) {
            if ($line -match 'uses:\s*\./') { continue }
            $line | Should -Match 'uses:\s*[^@]+@[0-9a-f]{40}\b' -Because "third-party action must be SHA-pinned: $line"
        }
    }

    It 'is registered on the ci-failure-watchdog watchlist' {
        $watchdog = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:WorkflowsDir 'ci-failure-watchdog.yml'))
        # After PR #944, the watchlist moved from `workflow_run.workflows` to `env.WATCHLIST`
        $watchlistRaw = $watchdog['env']['WATCHLIST']
        $watchlist = @($watchlistRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $watchlist | Should -Contain $script:WorkflowName
    }
}
