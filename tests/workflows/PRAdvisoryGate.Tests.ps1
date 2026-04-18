#Requires -Version 7.4
<#
Tests for `modules/shared/Invoke-PRAdvisoryGate.ps1` (#109).

Coverage:
  (a) squad-author detection (bot suffix, built-in identities,
      SQUAD_AGENT_LOGINS escape hatch, plain humans rejected)
  (b) fork-skip guard semantics (workflow-level expression is asserted
      via the workflow YAML check, runtime helper rejects empty author)
  (c) untagged finding -> [correctness] auto-tagging
  (d) Enabled = $false short-circuits without invoking gh

All `gh` and network calls are mocked.
#>

BeforeAll {
    $script:GatePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Invoke-PRAdvisoryGate.ps1'
    if (-not (Test-Path $script:GatePath)) {
        throw "Gate script not found at $script:GatePath"
    }

    # Dot-source so the helper functions are exposed without running main.
    . $script:GatePath
}

Describe 'Test-SquadAuthor' {
    BeforeEach {
        Remove-Item Env:SQUAD_AGENT_LOGINS -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:SQUAD_AGENT_LOGINS -ErrorAction SilentlyContinue
    }

    It 'accepts any login ending in [bot]' {
        Test-SquadAuthor -Login 'copilot[bot]'                       | Should -BeTrue
        Test-SquadAuthor -Login 'github-actions[bot]'                | Should -BeTrue
        Test-SquadAuthor -Login 'copilot-pull-request-reviewer[bot]' | Should -BeTrue
    }

    It 'accepts built-in squad identities (case-insensitive)' {
        Test-SquadAuthor -Login 'forge'    | Should -BeTrue
        Test-SquadAuthor -Login 'Atlas'    | Should -BeTrue
        Test-SquadAuthor -Login 'SENTINEL' | Should -BeTrue
        Test-SquadAuthor -Login 'copilot'  | Should -BeTrue
    }

    It 'rejects plain human logins by default' {
        Test-SquadAuthor -Login 'martinopedal' | Should -BeFalse
        Test-SquadAuthor -Login 'octocat'      | Should -BeFalse
    }

    It 'rejects empty / whitespace authors (fork-skip belt and braces)' {
        Test-SquadAuthor -Login ''     | Should -BeFalse
        Test-SquadAuthor -Login '   '  | Should -BeFalse
    }

    It 'honors the SQUAD_AGENT_LOGINS escape hatch' {
        $env:SQUAD_AGENT_LOGINS = 'custom-bot,another-agent'
        Test-SquadAuthor -Login 'custom-bot'    | Should -BeTrue
        Test-SquadAuthor -Login 'another-agent' | Should -BeTrue
        Test-SquadAuthor -Login 'unrelated'     | Should -BeFalse
    }
}

Describe 'Add-SeverityTag (untagged -> correctness, #108 fail-safe)' {
    It 'auto-tags an untagged finding as [correctness]' {
        $result = Add-SeverityTag -Finding 'missing $LASTEXITCODE check'
        $result | Should -Match '^\[correctness\] missing \$LASTEXITCODE check$'
    }

    It 'preserves an existing [blocker] tag' {
        Add-SeverityTag -Finding '[blocker] secrets leak in logs' |
            Should -Be '[blocker] secrets leak in logs'
    }

    It 'preserves [style] and [nit] tags verbatim' {
        Add-SeverityTag -Finding '[style] use single quotes here' |
            Should -Be '[style] use single quotes here'
        Add-SeverityTag -Finding '[nit] typo in comment' |
            Should -Be '[nit] typo in comment'
    }

    It 'normalizes tag casing to lowercase' {
        Add-SeverityTag -Finding '[BLOCKER] crash on empty input' |
            Should -Be '[blocker] crash on empty input'
        Add-SeverityTag -Finding '[Correctness] off by one' |
            Should -Be '[correctness] off by one'
    }

    It 'auto-tags an empty finding defensively' {
        $result = Add-SeverityTag -Finding ''
        $result | Should -Match '^\[correctness\]'
    }

    It 'tolerates leading whitespace before the tag' {
        Add-SeverityTag -Finding '   [style] indent' |
            Should -Be '[style] indent'
    }
}

Describe 'Format-AdvisoryComment' {
    It 'always embeds the squad-advisory marker' {
        $body = Format-AdvisoryComment -PRNumber 42 -Findings @() -Verdict 'clean'
        $body | Should -Match '<!-- squad-advisory -->'
        $body | Should -Match 'PR #42'
    }

    It 'auto-tags untagged findings inside the rendered body' {
        $body = Format-AdvisoryComment -PRNumber 7 -Findings @(
            'missing error handling',
            '[style] use single quotes'
        )
        $body | Should -Match '\[correctness\] missing error handling'
        $body | Should -Match '\[style\] use single quotes'
    }

    It 'escalates verdict to "blockers" when any finding is veto-class' {
        $body = Format-AdvisoryComment -PRNumber 3 -Findings @(
            '[blocker] panics on null',
            '[style] minor'
        ) -Verdict 'clean'
        $body | Should -Match '(?m)\*\*Verdict:\*\*\s+\[X\]\s+blockers'
    }

    It 'reports clean verdict when no findings are present' {
        $body = Format-AdvisoryComment -PRNumber 1 -Findings @() -Verdict 'clean'
        $body | Should -Match '(?m)\*\*Verdict:\*\*\s+\[OK\]\s+clean'
        $body | Should -Match 'Triage bundle queued'
    }
}

Describe 'Disable switch short-circuits (Enabled = $false)' {
    BeforeEach {
        # If gh is somehow invoked the test must fail loudly.
        function global:gh {
            throw 'gh must NOT be invoked when SQUAD_ADVISORY_GATE=0'
        }
    }

    AfterEach {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
    }

    It 'returns without calling gh when disabled' {
        {
            & $script:GatePath `
                -PRNumber 99 `
                -Repo 'martinopedal/azure-analyzer' `
                -PRAuthor 'copilot[bot]' `
                -Enabled:$false
        } | Should -Not -Throw
    }

    It 'returns without calling gh when author is human and enabled' {
        {
            & $script:GatePath `
                -PRNumber 99 `
                -Repo 'martinopedal/azure-analyzer' `
                -PRAuthor 'martinopedal' `
                -Enabled:$true `
                -DryRun
        } | Should -Not -Throw
    }
}

Describe 'Workflow YAML safety (#109)' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'pr-advisory-gate.yml'
    }

    It 'pins actions/checkout to a SHA (no floating tags)' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match 'actions/checkout@[0-9a-f]{40}'
    }

    It 'declares a fork-skip guard on head.repo.full_name' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match 'head\.repo\.full_name == github\.repository'
    }

    It 'uses pull_request_target (not pull_request)' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match 'pull_request_target:'
        $content | Should -Not -Match '(?m)^\s*pull_request:\s*$'
    }

    It 'declares a concurrency group keyed on PR number with cancel-in-progress' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match 'group:\s*pr-advisory-gate-\$\{\{\s*github\.event\.pull_request\.number'
        $content | Should -Match 'cancel-in-progress:\s*true'
    }

    It 'never interpolates ${{ }} into bash run blocks (uses env vars)' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        # PR_NUMBER, REPO_NAME, PR_AUTHOR must come from env, not inline.
        $content | Should -Match '\$env:PR_NUMBER'
        $content | Should -Match '\$env:REPO_NAME'
        $content | Should -Match '\$env:PR_AUTHOR'
    }

    It 'honors the SQUAD_ADVISORY_GATE repo variable with a default of 1' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match "vars\.SQUAD_ADVISORY_GATE \|\| '1'"
    }
}
