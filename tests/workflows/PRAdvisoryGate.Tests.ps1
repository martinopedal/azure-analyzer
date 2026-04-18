#Requires -Version 7.4
<#
Tests for `modules/shared/Invoke-PRAdvisoryGate.ps1` (#109).

Coverage:
  (a) squad-author detection (swe-agent bot pattern, built-in identities,
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

    It 'accepts squad swe-agent bot logins' {
        Test-SquadAuthor -Login 'copilot-swe-agent[bot]' | Should -BeTrue
        Test-SquadAuthor -Login 'atlas-swe-agent[bot]'   | Should -BeTrue
    }

    It 'accepts built-in squad identities (case-insensitive)' {
        Test-SquadAuthor -Login 'forge'    | Should -BeTrue
        Test-SquadAuthor -Login 'Atlas'    | Should -BeTrue
        Test-SquadAuthor -Login 'SENTINEL' | Should -BeTrue
    }

    It 'rejects non-squad automation bots' {
        Test-SquadAuthor -Login 'dependabot[bot]'     | Should -BeFalse
        Test-SquadAuthor -Login 'renovate[bot]'       | Should -BeFalse
        Test-SquadAuthor -Login 'github-actions[bot]' | Should -BeFalse
        Test-SquadAuthor -Login 'copilot[bot]'        | Should -BeFalse
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

    It 'preserves an existing [security] tag verbatim' {
        Add-SeverityTag -Finding '[security] token leak in logs' |
            Should -Be '[security] token leak in logs'
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

    It 'escalates verdict to "blockers" when a [security] finding exists' {
        $body = Format-AdvisoryComment -PRNumber 3 -Findings @(
            '[security] token leak in logs',
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

Describe 'Skip-advisory label bypass' {
    BeforeEach {
        $env:PR_LABELS = 'skip-advisory,bug'
        function global:gh {
            throw 'gh must NOT be invoked when skip-advisory label is present'
        }
    }

    AfterEach {
        Remove-Item Env:PR_LABELS -ErrorAction SilentlyContinue
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
    }

    It 'short-circuits silently when skip-advisory label is present' {
        {
            & $script:GatePath `
                -PRNumber 139 `
                -Repo 'martinopedal/azure-analyzer' `
                -PRAuthor 'copilot-swe-agent[bot]' `
                -Enabled:$true
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

    It 'sets timeout-minutes to 5 on the advisory job' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match '(?ms)advisory-gate:\s+.*?timeout-minutes:\s*5'
    }

    It 'marks the advisory job as continue-on-error' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match '(?ms)advisory-gate:\s+.*?continue-on-error:\s*true'
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

Describe 'Get-AdvisoryCommentId pagination and marker selection' {
    BeforeEach {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] [object[]]$Args)

            $global:LASTEXITCODE = 0
            if ($Args[0] -eq 'api' -and $Args[1] -eq 'repos/martinopedal/azure-analyzer/issues/139/comments') {
                if (-not ($Args -contains '--paginate')) { throw 'expected --paginate' }
                if (-not ($Args -contains '--slurp')) { throw 'expected --slurp' }
                return @'
[
  [
    {"id": 11, "body": "first page comment"},
    {"id": 21, "body": "<!-- squad-advisory --> old marker"}
  ],
  [
    {"id": 31, "body": "second page comment"},
    {"id": 42, "body": "<!-- squad-advisory --> newest marker"}
  ]
]
'@
            }

            throw "unexpected gh invocation: $($Args -join ' ')"
        }
    }

    AfterEach {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
    }

    It 'parses paginated slurped comments and returns the newest marker id' {
        $id = Get-AdvisoryCommentId -PRNumber 139 -Repo 'martinopedal/azure-analyzer'
        $id | Should -Be 42
    }
}

Describe 'Publish-AdvisoryComment idempotent update target' {
    BeforeEach {
        $script:PatchedEndpoint = $null
        $script:PostedEndpoint = $null

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] [object[]]$Args)

            $global:LASTEXITCODE = 0
            if ($Args[0] -eq 'api' -and $Args[1] -eq 'repos/martinopedal/azure-analyzer/issues/139/comments') {
                if (-not ($Args -contains '--paginate')) { throw 'expected --paginate' }
                if (-not ($Args -contains '--slurp')) { throw 'expected --slurp' }
                return @'
[
  [
    {"id": 77, "body": "<!-- squad-advisory --> older marker"},
    {"id": 99, "body": "<!-- squad-advisory --> newest marker"}
  ]
]
'@
            }

            if ($Args[0] -eq 'api' -and $Args[1] -eq '-X' -and $Args[2] -eq 'PATCH') {
                $script:PatchedEndpoint = [string]$Args[3]
                return '{}'
            }

            if ($Args[0] -eq 'api' -and $Args[1] -eq '-X' -and $Args[2] -eq 'POST') {
                $script:PostedEndpoint = [string]$Args[3]
                return '{}'
            }

            throw "unexpected gh invocation: $($Args -join ' ')"
        }
    }

    AfterEach {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        Remove-Variable -Name PatchedEndpoint -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name PostedEndpoint -Scope Script -ErrorAction SilentlyContinue
    }

    It 'patches the newest advisory marker comment when duplicates exist' {
        Publish-AdvisoryComment `
            -PRNumber 139 `
            -Repo 'martinopedal/azure-analyzer' `
            -Body "<!-- squad-advisory -->`nhello" | Out-Null

        $script:PatchedEndpoint | Should -Be 'repos/martinopedal/azure-analyzer/issues/comments/99'
        $script:PostedEndpoint | Should -BeNullOrEmpty
    }
}
