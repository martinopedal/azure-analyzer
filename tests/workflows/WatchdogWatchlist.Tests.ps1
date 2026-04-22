#Requires -Version 7.4
<#
Asserts every workflow name in ci-failure-watchdog.yml's `workflows:` allow-
list resolves to a real `name:` field in some .github/workflows/*.yml file.
This is the regression guard against the #111 / #154 phantom-failure pattern
where a typo in the watchlist silently breaks failure triage for that
workflow.
#>

BeforeAll {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Install-Module powershell-yaml -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop | Out-Null
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:WatchdogPath = Join-Path $script:WorkflowsDir 'ci-failure-watchdog.yml'
    if (-not (Test-Path $script:WatchdogPath)) {
        throw "Watchdog workflow missing at $script:WatchdogPath"
    }

    $script:AllNames = @{}
    foreach ($wf in (Get-ChildItem $script:WorkflowsDir -Filter *.yml)) {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $wf.FullName)
        if ($parsed.ContainsKey('name')) {
            $script:AllNames[$parsed['name']] = $wf.Name
        }
    }

    $watchdog = ConvertFrom-Yaml (Get-Content -Raw $script:WatchdogPath)
    # In powershell-yaml, the `on:` key is parsed to True (boolean) because
    # YAML 1.1 treats `on` as truthy. Defend against both spellings.
    $onBlock = if ($watchdog.ContainsKey('on')) { $watchdog['on'] } else { $watchdog[$true] }
    $script:Watchlist = @($onBlock['workflow_run']['workflows'])
}

Describe 'CI failure watchdog watchlist' {
    It 'declares a non-empty workflows: trigger key (regression guard for #111)' {
        $script:Watchlist.Count | Should -BeGreaterThan 0
    }

    It 'has every watched name resolving to a real workflow file' {
        $missing = @()
        foreach ($name in $script:Watchlist) {
            if (-not $script:AllNames.ContainsKey($name)) {
                $missing += $name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "every watched workflow must have an exact `name:` match in .github/workflows/. Missing: $($missing -join ', ')"
    }

    It 'does not watch the watchdog itself' {
        $script:Watchlist | Should -Not -Contain 'CI failure watchdog'
    }

    It 'covers the critical squad + PR-gate workflows' {
          $required = @('CI', 'CodeQL', 'Docs Check', 'PR Review Gate', 'PR Advisory Gate', 'PR Auto-Resolve Review Threads', 'Squad Heartbeat (Ralph)', 'PR Auto-Rerun On Push', 'PR Auto-Rebase Conflicts')
        foreach ($r in $required) {
            $script:Watchlist | Should -Contain $r -Because "watchlist must guard the $r workflow"
        }
    }
}

Describe 'CI Health Digest workflow' {
    It 'exists and is parseable YAML' {
        $path = Join-Path $script:WorkflowsDir 'ci-health-digest.yml'
        Test-Path $path | Should -BeTrue
        { ConvertFrom-Yaml (Get-Content -Raw $path) } | Should -Not -Throw
    }

    It 'runs on a daily cron and supports manual dispatch' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:WorkflowsDir 'ci-health-digest.yml'))
        $onBlock = if ($parsed.ContainsKey('on')) { $parsed['on'] } else { $parsed[$true] }
        $onBlock.ContainsKey('schedule') | Should -BeTrue
        $onBlock.ContainsKey('workflow_dispatch') | Should -BeTrue
    }

    It 'declares minimal least-privilege permissions' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $script:WorkflowsDir 'ci-health-digest.yml'))
        $perms = $parsed['permissions']
        $perms['issues'] | Should -Be 'write'
        $perms['actions'] | Should -Be 'read'
        $perms['contents'] | Should -Be 'read'
    }
}
