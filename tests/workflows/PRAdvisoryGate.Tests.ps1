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

    It 'grants statuses: write so the rubberduck-gate commit status can be posted (#173)' {
        $lines = Get-Content -Path $script:WorkflowPath
        # Locate the top-level `permissions:` block and assert one of the
        # following indented lines declares `statuses: write`. Avoids any
        # multiline regex that could backtrack.
        $startIdx = ($lines | Select-String -Pattern '^permissions:\s*$' | Select-Object -First 1).LineNumber
        $startIdx | Should -Not -BeNullOrEmpty
        $block = $lines[$startIdx..([Math]::Min($startIdx + 9, $lines.Length - 1))]
        ($block -match '^\s+statuses:\s*write\s*$') | Should -Not -BeNullOrEmpty
    }

    It 'post-status step uses if: always() so it fires even when the gate body fails (#173)' {
        $lines = Get-Content -Path $script:WorkflowPath
        $stepIdx = ($lines | Select-String -Pattern 'Post rubberduck-gate commit status' | Select-Object -First 1).LineNumber
        $stepIdx | Should -Not -BeNullOrEmpty
        # Look for `if: always()` within the next 8 lines after the step name.
        $window = $lines[$stepIdx..([Math]::Min($stepIdx + 8, $lines.Length - 1))]
        ($window -match 'if:\s*always\(\)') | Should -Not -BeNullOrEmpty
    }

    It 'post-status step does NOT gate on a non-empty gate-state output (#173)' {
        # Branch protection requires the rubberduck-gate context on every PR
        # head SHA. Skipped runs must still post a (success) status, so the
        # `if:` condition must not short-circuit on an empty gate-state.
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Not -Match "gate-state\s*!=\s*''"
    }

    It 'post-status step env wires PR_HEAD_SHA and GATE_STATE through to pwsh (#173)' {
        $lines = Get-Content -Path $script:WorkflowPath
        $stepIdx = ($lines | Select-String -Pattern 'Post rubberduck-gate commit status' | Select-Object -First 1).LineNumber
        $stepIdx | Should -Not -BeNullOrEmpty
        $window = $lines[$stepIdx..([Math]::Min($stepIdx + 25, $lines.Length - 1))]
        ($window -match 'PR_HEAD_SHA:\s*\$\{\{\s*github\.event\.pull_request\.head\.sha\s*\}\}') | Should -Not -BeNullOrEmpty
        ($window -match 'GATE_STATE:\s*\$\{\{\s*steps\.gate\.outputs\.gate-state\s*\}\}') | Should -Not -BeNullOrEmpty
    }

    It 'post-status step posts the rubberduck-gate context against the head SHA' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match "context='rubberduck-gate'"
        $content | Should -Match 'repos/\$env:REPO_NAME/statuses/\$env:PR_HEAD_SHA'
    }

    It 'degraded advisory catch block emits success and a degraded skip-reason' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match 'PR advisory gate degraded to advisory no-op'
        $content | Should -Match '"gate-state=success"'
        $content | Should -Match '"skip-reason=\$skipReason"'
        $content | Should -Match '\$skipReason = \("degraded: \$safeMessage"'
    }

    It 'calls Get-CopilotReviewFindings with separate owner and repo-name args' {
        $content = Get-Content -Path $script:WorkflowPath -Raw
        $content | Should -Match '\$owner,\s*\$repo\s*=\s*\$env:REPO_NAME\.Split\(''/'''
        $content | Should -Match 'Get-CopilotReviewFindings\s+`[\s\r\n]+-Owner \$owner\s+`[\s\r\n]+-Repo \$repo'
    }
}

Describe 'Skip-path gate-state emission (#173)' {
    BeforeAll {
        # Each It block writes a unique fake GITHUB_OUTPUT so we can assert
        # the script always emits a default gate-state on early-return paths.
        function script:New-GhOutputFile {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gh-out-" + [guid]::NewGuid().ToString('N') + '.txt')
            New-Item -Path $tmp -ItemType File -Force | Out-Null
            return $tmp
        }
    }

    It 'emits gate-state=success with skip-reason=disabled when -Enabled:$false' {
        $out = New-GhOutputFile
        $env:GITHUB_OUTPUT = $out
        try {
            & $script:GatePath `
                -PRNumber 99 `
                -Repo 'martinopedal/azure-analyzer' `
                -PRAuthor 'copilot[bot]' `
                -HeadSha 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' `
                -Enabled:$false
            $written = Get-Content -Path $out -Raw
            $written | Should -Match 'gate-state=success'
            $written | Should -Match 'skip-reason=disabled'
            $written | Should -Match 'head-sha=deadbeef'
        } finally {
            Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item $out -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits gate-state=success with skip-reason=non-squad-author for human PR authors' {
        $out = New-GhOutputFile
        $env:GITHUB_OUTPUT = $out
        try {
            & $script:GatePath `
                -PRNumber 99 `
                -Repo 'martinopedal/azure-analyzer' `
                -PRAuthor 'martinopedal' `
                -HeadSha 'cafef00dcafef00dcafef00dcafef00dcafef00d' `
                -Enabled:$true `
                -DryRun
            $written = Get-Content -Path $out -Raw
            $written | Should -Match 'gate-state=success'
            $written | Should -Match 'skip-reason=non-squad-author'
            $written | Should -Match 'head-sha=cafef00d'
        } finally {
            Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item $out -Force -ErrorAction SilentlyContinue
        }
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



Describe 'Get-FrontierModelRoster (frontier-only allow-list)' {
    It 'returns exactly the three frontier models in order' {
        $roster = @(Get-FrontierModelRoster)
        $roster.Count | Should -Be 3
        $roster[0] | Should -Be 'claude-opus-4.7'
        $roster[1] | Should -Be 'gpt-5.3-codex'
        $roster[2] | Should -Be 'goldeneye'
    }

    It 'contains no forbidden non-frontier models' {
        $roster = @(Get-FrontierModelRoster)
        $forbidden = @(
            'claude-opus-4.6', 'claude-opus-4.5',
            'claude-sonnet-4.5', 'claude-sonnet-4.6',
            'claude-haiku-4.5', 'gpt-5-mini', 'gpt-5.4-mini', 'gpt-4.1'
        )
        foreach ($bad in $forbidden) {
            $roster | Should -Not -Contain $bad
        }
    }
}

Describe 'Resolve-RubberDuckVerdict (Gate-pass criteria #108)' {
    It 'passes when 3-of-3 APPROVE with zero findings' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
        )
        $r.Passed | Should -BeTrue
        $r.Approves | Should -Be 3
        $r.Verdict | Should -Be 'clean'
    }

    It 'passes when 2-of-3 APPROVE with only [style]/[nit] findings' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @('[style] use single quotes') }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'REQUEST_CHANGES'; Findings = @('[nit] typo') }
        )
        $r.Passed | Should -BeTrue
        $r.Verdict | Should -Be 'concerns'
    }

    It 'fails when any [blocker] finding exists, even with 3-of-3 APPROVE (rule 1 veto)' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @('[blocker] secrets leak') }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
        )
        $r.Passed | Should -BeFalse
        $r.Verdict | Should -Be 'blockers'
    }

    It 'fails when any [correctness] finding exists' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @('[correctness] off by one') }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
        )
        $r.Passed | Should -BeFalse
        $r.Verdict | Should -Be 'blockers'
    }

    It 'fails when fewer than 2 APPROVE even with no veto findings' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'REQUEST_CHANGES'; Findings = @('[style] x') }
            [pscustomobject]@{ Verdict = 'REQUEST_CHANGES'; Findings = @('[nit] y') }
        )
        $r.Passed | Should -BeFalse
    }

    It 'auto-tags untagged findings as [correctness] (fail-safe)' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @('something untagged') }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
        )
        $r.Passed | Should -BeFalse
        $r.Verdict | Should -Be 'blockers'
        $r.Findings[0] | Should -Match '^\[correctness\]'
    }

    It 'fails when consensus passes but Copilot threads are not addressed' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @('[style] optional rename') }
            [pscustomobject]@{ Verdict = 'REQUEST_CHANGES'; Findings = @('[nit] wording') }
        ) -AllCopilotThreadsAddressed:$false
        $r.Passed | Should -BeFalse
        $r.AllCopilotThreadsAddressed | Should -BeFalse
    }

    It 'passes when consensus passes and Copilot threads are addressed' {
        $r = Resolve-RubberDuckVerdict -Responses @(
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'APPROVE'; Findings = @() }
            [pscustomobject]@{ Verdict = 'REQUEST_CHANGES'; Findings = @('[style] x') }
        ) -AllCopilotThreadsAddressed:$true
        $r.Passed | Should -BeTrue
        $r.AllCopilotThreadsAddressed | Should -BeTrue
    }
}

Describe 'Invoke-RubberDuckModel (per-SHA prompt persistence)' {
    It 'writes a prompt file keyed to PR + head SHA + model name' {
        $outDir = Join-Path $TestDrive 'inbox'
        $resp = Invoke-RubberDuckModel `
            -ModelName 'claude-opus-4.7' `
            -Prompt 'hello world prompt' `
            -PRNumber 42 `
            -HeadSha 'abc123def456' `
            -OutputPath $outDir
        $resp.Verdict | Should -Be 'APPROVE'
        $resp.Stub | Should -BeTrue
        Get-ChildItem -Path $outDir -Filter '42-abc123def456-nocopilotfinding-claude-opus-4.7.md' |
            Should -Not -BeNullOrEmpty
    }

    It 'persists a fresh prompt file per head SHA (idempotent per commit)' {
        $outDir = Join-Path $TestDrive 'inbox-iter'
        Invoke-RubberDuckModel -ModelName 'gpt-5.3-codex' -Prompt 'p1' -PRNumber 7 -HeadSha 'sha1aaaaaaaa' -OutputPath $outDir | Out-Null
        Invoke-RubberDuckModel -ModelName 'gpt-5.3-codex' -Prompt 'p2' -PRNumber 7 -HeadSha 'sha2bbbbbbbb' -OutputPath $outDir | Out-Null
        (Get-ChildItem -Path $outDir).Count | Should -Be 4
    }

    It 'DryRun skips disk writes' {
        $outDir = Join-Path $TestDrive 'inbox-dry'
        $resp = Invoke-RubberDuckModel -ModelName 'goldeneye' -Prompt 'p' -PRNumber 1 -HeadSha 'abc' -OutputPath $outDir -DryRun
        $resp.Verdict | Should -Be 'APPROVE'
        Test-Path $outDir | Should -BeFalse
    }
}

Describe 'Format-AdvisoryComment (head SHA stamping for idempotent updates)' {
    It 'embeds the head SHA marker comment when provided' {
        $body = Format-AdvisoryComment -PRNumber 42 -Findings @() -Verdict 'clean' -HeadSha 'deadbeefcafe'
        $body | Should -Match '<!-- head-sha: deadbeefcafe -->'
        $body | Should -Match '\*\*Head SHA:\*\*\s+`deadbee`'
    }

    It 'embeds the model APPROVE counter when TotalModels is provided' {
        $body = Format-AdvisoryComment -PRNumber 42 -Findings @() -Verdict 'clean' -Approves 2 -TotalModels 3
        $body | Should -Match '\*\*Models APPROVE:\*\*\s+2 / 3'
    }

    It 'omits SHA / model lines when not provided (back-compat)' {
        $body = Format-AdvisoryComment -PRNumber 42 -Findings @() -Verdict 'clean'
        $body | Should -Not -Match 'Head SHA'
        $body | Should -Not -Match 'Models APPROVE'
    }
}

Describe 'Frontier fallback chain (retry + swap, #157 follow-up)' {

    Context 'Get-FrontierFallbackChain (frontier-only allow-list)' {
        It 'lists exactly the 5 frontier models in fallback order' {
            $chain = Get-FrontierFallbackChain
            $chain | Should -BeExactly @(
                'claude-opus-4.7',
                'claude-opus-4.6-1m',
                'gpt-5.4',
                'gpt-5.3-codex',
                'goldeneye'
            )
        }

        It 'rejects forbidden families (sonnet / haiku / mini / gpt-4.1 / opus-4.6 base / opus-4.5)' {
            $chain = Get-FrontierFallbackChain
            $forbidden = @('sonnet', 'haiku', 'mini', 'gpt-4.1', 'opus-4.5')
            foreach ($needle in $forbidden) {
                ($chain -join ' ') | Should -Not -Match $needle
            }
            # opus-4.6 base (no `-1m`) is forbidden, but opus-4.6-1m is allowed.
            ($chain | Where-Object { $_ -eq 'claude-opus-4.6' }) | Should -BeNullOrEmpty
        }
    }

    Context 'Test-RetryableModelError classification' {
        It 'flags HTTP 429 / 503 / 504 as retryable' {
            (Test-RetryableModelError -StatusCode 429) | Should -BeTrue
            (Test-RetryableModelError -StatusCode 503) | Should -BeTrue
            (Test-RetryableModelError -StatusCode 504) | Should -BeTrue
        }

        It 'flags rate_limit / quota_exceeded / overloaded / throttle / socket timeout' {
            (Test-RetryableModelError -Message 'error: rate_limit hit on tenant') | Should -BeTrue
            (Test-RetryableModelError -Message 'quota_exceeded for tier') | Should -BeTrue
            (Test-RetryableModelError -Message 'model overloaded, retry later') | Should -BeTrue
            (Test-RetryableModelError -Message 'request throttled by gateway') | Should -BeTrue
            (Test-RetryableModelError -Message 'socket timeout after 30s') | Should -BeTrue
        }

        It 'does NOT flag non-transient errors (4xx other than 429, generic exceptions)' {
            (Test-RetryableModelError -StatusCode 400) | Should -BeFalse
            (Test-RetryableModelError -StatusCode 401) | Should -BeFalse
            (Test-RetryableModelError -Message 'invalid_request: bad prompt') | Should -BeFalse
            (Test-RetryableModelError -Message '') | Should -BeFalse
        }

        It 'detects context_length_exceeded (immediate-swap signal)' {
            (Test-ContextOverflowError -Message 'context_length_exceeded for model x') | Should -BeTrue
            (Test-ContextOverflowError -Message 'maximum context tokens reached') | Should -BeTrue
            (Test-ContextOverflowError -Message 'rate_limit') | Should -BeFalse
        }
    }

    Context 'Get-RetryBackoffSeconds (1s / 4s / 16s with +/-25% jitter)' {
        It 'produces increasing base delays for attempts 0/1/2 (no-jitter check on a deterministic Random)' {
            # Use a seeded Random so jitter is deterministic.
            $rng = [System.Random]::new(42)
            $d0 = Get-RetryBackoffSeconds -Attempt 0 -Random $rng
            $rng = [System.Random]::new(42)
            $d1 = Get-RetryBackoffSeconds -Attempt 1 -Random $rng
            $rng = [System.Random]::new(42)
            $d2 = Get-RetryBackoffSeconds -Attempt 2 -Random $rng
            # With identical seed the jitter factor is identical, so the
            # ratio between attempts is exactly 4x.
            ($d1 / $d0) | Should -BeGreaterThan 3.9
            ($d2 / $d1) | Should -BeGreaterThan 3.9
        }

        It 'keeps the jittered delay within +/-25% of the base for many seeds' {
            for ($seed = 1; $seed -le 50; $seed++) {
                $rng = [System.Random]::new($seed)
                $d = Get-RetryBackoffSeconds -Attempt 0 -Random $rng -BaseSeconds 1
                $d | Should -BeGreaterOrEqual 0.74
                $d | Should -BeLessOrEqual 1.26
            }
        }
    }

    Context 'Invoke-ModelWithRetry (per-model 3-attempt loop)' {
        It 'TEST 1 - 429 on first call, succeeds on retry 2 (no further attempts)' {
            $script:invokeCount = 0
            $sleepCalls = [System.Collections.Generic.List[double]]::new()
            $invoker = {
                param($model, $ctx)
                $script:invokeCount++
                if ($script:invokeCount -lt 2) {
                    throw 'HTTP 429: rate_limit on tenant'
                }
                return [pscustomobject]@{ Model = $model; Verdict = 'APPROVE'; Findings = @() }
            }
            $sleep = { param($s) $sleepCalls.Add([double]$s) }
            $result = Invoke-ModelWithRetry -ModelName 'claude-opus-4.7' -CallContext @{} -CallInvoker $invoker -Sleep $sleep
            $result.Outcome | Should -Be 'Success'
            $result.Attempts | Should -Be 2
            $result.Response.Verdict | Should -Be 'APPROVE'
            $sleepCalls.Count | Should -Be 1   # exactly one backoff sleep between attempt 1 and 2
            $sleepCalls[0] | Should -BeGreaterThan 0
        }

        It 'TEST 3 - context_length_exceeded short-circuits retries (no backoff exhaustion)' {
            $script:invokeCount = 0
            $sleepCalls = [System.Collections.Generic.List[double]]::new()
            $invoker = {
                param($m, $c)
                $script:invokeCount++
                throw 'context_length_exceeded: prompt is too large'
            }
            $sleep = { param($s) $sleepCalls.Add([double]$s) }
            $result = Invoke-ModelWithRetry -ModelName 'claude-opus-4.7' -CallContext @{} -CallInvoker $invoker -Sleep $sleep
            $result.Outcome | Should -Be 'ContextOverflow'
            $result.Attempts | Should -Be 1
            $sleepCalls.Count | Should -Be 0   # no backoff: it's a swap signal
        }

        It 'returns Exhausted after MaxRetries on persistent transient errors' {
            $script:invokeCount = 0
            $invoker = {
                param($m, $c); $script:invokeCount++; throw 'HTTP 503 service_unavailable'
            }
            $sleep = { param($s) }   # no-op
            $result = Invoke-ModelWithRetry -ModelName 'gpt-5.4' -CallContext @{} -CallInvoker $invoker -Sleep $sleep -MaxRetries 3
            $result.Outcome | Should -Be 'Exhausted'
            $result.Attempts | Should -Be 3
            $script:invokeCount | Should -Be 3
        }

        It 'returns Fatal immediately on a non-retryable 400-class error' {
            $script:invokeCount = 0
            $invoker = {
                param($m, $c); $script:invokeCount++; throw 'invalid_request_error: bad payload'
            }
            $sleep = { param($s) }
            $result = Invoke-ModelWithRetry -ModelName 'goldeneye' -CallContext @{} -CallInvoker $invoker -Sleep $sleep
            $result.Outcome | Should -Be 'Fatal'
            $script:invokeCount | Should -Be 1
        }
    }

    Context 'Invoke-RubberDuckTrio (per-call swap orchestrator)' {

        BeforeAll {
            $script:auditDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gate-fallback-tests-" + [guid]::NewGuid().Guid)
            New-Item -Path $script:auditDir -ItemType Directory -Force | Out-Null
        }

        AfterAll {
            if (Test-Path $script:auditDir) { Remove-Item $script:auditDir -Recurse -Force }
        }

        It 'TEST 2 - persistent 429 on opus-4.7, swaps to opus-4.6-1m, succeeds' {
            $script:perModelCalls = @{}
            $invoker = {
                param($m, $c)
                if (-not $script:perModelCalls.ContainsKey($m)) { $script:perModelCalls[$m] = 0 }
                $script:perModelCalls[$m]++
                if ($m -eq 'claude-opus-4.7') {
                    throw 'HTTP 429 rate_limit'
                }
                return [pscustomobject]@{ Model = $m; Verdict = 'APPROVE'; Findings = @() }
            }
            $sleep = { param($s) }

            $result = Invoke-RubberDuckTrio `
                -PRNumber 42 -HeadSha 'cafebabecafe' `
                -CallContext @{} -CallInvoker $invoker `
                -OutputPath $script:auditDir -Sleep $sleep
            $result.Outcome | Should -Be 'Success'
            $result.Verdicts.Count | Should -Be 3
            # opus-4.7 is the first slot AND first chain entry: it should
            # have been retried 3 times then swapped out exactly once.
            $script:perModelCalls['claude-opus-4.7'] | Should -Be 3
            # The swap target must be the next chain entry (opus-4.6-1m).
            $modelsHit = @($result.Verdicts | ForEach-Object Model)
            $modelsHit | Should -Contain 'claude-opus-4.6-1m'
            $modelsHit | Should -Contain 'gpt-5.3-codex'
            $modelsHit | Should -Contain 'goldeneye'
            $modelsHit | Should -Not -Contain 'claude-opus-4.7'
            $result.Swaps | Should -Be 1

            # Audit row exists for the swap.
            $auditFiles = @(Get-ChildItem $script:auditDir -Filter 'gate-fallback-42-*')
            $auditFiles.Count | Should -BeGreaterOrEqual 1
            ($auditFiles.Name -join ' ') | Should -Match 'claude-opus-4\.7-to-claude-opus-4\.6-1m'
        }

        It 'TEST 4 - all 5 chain entries fail, returns ChainExhausted (gate fails closed)' {
            $invoker = {
                param($m, $c); throw 'HTTP 503 service_unavailable'
            }
            $sleep = { param($s) }
            $result = Invoke-RubberDuckTrio `
                -PRNumber 99 -HeadSha 'deadbeef0000' `
                -CallContext @{} -CallInvoker $invoker `
                -OutputPath $script:auditDir -Sleep $sleep
            $result.Outcome | Should -BeIn 'ChainExhausted', 'SwapLimitExceeded'
            $result.Verdicts.Count | Should -Be 0

            # Sticky-comment formatter produces the expected user-facing text.
            $sticky = Format-ChainExhaustedComment -PRNumber 99 -HeadSha 'deadbeef0000' -Swaps $result.Swaps
            $sticky | Should -Match 'Gate could not reach any frontier model'
            $sticky | Should -Match 'Manual review required'
            $sticky | Should -Match 'fail-closed'
            $sticky | Should -Match '<!-- squad-advisory -->'
        }

        It 'TEST 5 - a model that already returned a verdict is NEVER re-invoked' {
            # Force opus-4.7 to succeed, gpt-5.3-codex to always fail (forces
            # swap into the chain), goldeneye to succeed. The swap candidate
            # MUST skip opus-4.7 (already used) and pick opus-4.6-1m next.
            $script:calls = [System.Collections.Generic.List[string]]::new()
            $invoker = {
                param($m, $c)
                $script:calls.Add($m)
                if ($m -eq 'gpt-5.3-codex') { throw 'HTTP 429 rate_limit' }
                return [pscustomobject]@{ Model = $m; Verdict = 'APPROVE'; Findings = @() }
            }
            $sleep = { param($s) }
            $result = Invoke-RubberDuckTrio `
                -PRNumber 7 -HeadSha 'aaaabbbbcccc' `
                -CallContext @{} -CallInvoker $invoker `
                -OutputPath $script:auditDir -Sleep $sleep
            $result.Outcome | Should -Be 'Success'
            $modelsHit = @($result.Verdicts | ForEach-Object Model)
            $modelsHit | Should -Contain 'claude-opus-4.7'
            $modelsHit | Should -Contain 'goldeneye'
            $modelsHit | Should -Contain 'claude-opus-4.6-1m'   # the substitute
            $modelsHit | Should -Not -Contain 'gpt-5.3-codex'

            # opus-4.7 was called exactly once (the successful initial call).
            ($script:calls | Where-Object { $_ -eq 'claude-opus-4.7' } | Measure-Object).Count | Should -Be 1
            # gpt-5.3-codex was retried up to MaxRetries before swap.
            ($script:calls | Where-Object { $_ -eq 'gpt-5.3-codex' } | Measure-Object).Count | Should -Be 3
        }
    }
}
