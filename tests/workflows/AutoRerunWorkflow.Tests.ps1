#Requires -Version 7.4
<#
Asserts the PR Auto-Rerun On Push workflow exists, has the correct trigger,
permissions, concurrency, cost-optimized rerun flag, SHA-pinned third-party
actions, and is registered on the watchdog watchlist. This is the regression
guard for repo directive 2026-04-22T23:26:00Z (auto-retry agent-branch failed
checks at the workflow layer so the iterate-until-green loop only engages on
the SECOND failure).
#>

BeforeAll {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Install-Module powershell-yaml -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop | Out-Null
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:WorkflowPath = Join-Path $script:WorkflowsDir 'pr-auto-rerun-on-push.yml'
    $script:WorkflowName = 'PR Auto-Rerun On Push'
}

Describe 'PR Auto-Rerun On Push workflow' {
    It 'exists at the canonical path' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'parses as valid YAML' {
        { ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath) } | Should -Not -Throw
    }

    It 'declares the canonical workflow name (used by watchdog watchlist)' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $parsed['name'] | Should -Be $script:WorkflowName
    }

    It 'triggers on pull_request synchronize and supports workflow_dispatch' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $onBlock = if ($parsed.ContainsKey('on')) { $parsed['on'] } else { $parsed[$true] }
        $onBlock.ContainsKey('pull_request') | Should -BeTrue
        $onBlock.ContainsKey('workflow_dispatch') | Should -BeTrue
        @($onBlock['pull_request']['types']) | Should -Contain 'synchronize'
    }

    It 'declares the required permissions for rerun + comment posting' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $perms = $parsed['permissions']
        $perms['actions']       | Should -Be 'write'
        $perms['pull-requests'] | Should -Be 'write'
        $perms['contents']      | Should -Be 'read'
        $perms['checks']        | Should -Be 'read'
    }

    It 'uses gh run rerun --failed (cost-optimized, not full rerun)' {
        $content = Get-Content -Raw $script:WorkflowPath
        $content | Should -Match 'gh run rerun [^\n]*--failed'
    }

    It 'has a per-PR concurrency group with cancel-in-progress' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $parsed['concurrency']['group'] | Should -Match 'auto-rerun-pr-'
        $parsed['concurrency']['cancel-in-progress'] | Should -BeTrue
    }

    It 'filters to agent-owned branch prefixes (squad/copilot/fix/ci/feat)' {
        $content = Get-Content -Raw $script:WorkflowPath
        foreach ($prefix in @('squad/', 'copilot/', 'fix/', 'ci/', 'feat/')) {
            $content | Should -Match ([regex]::Escape($prefix))
        }
    }

    It 'waits for initial check runs to register before enumerating' {
        $content = Get-Content -Raw $script:WorkflowPath
        $content | Should -Match 'sleep 30'
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
