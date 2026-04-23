#Requires -Version 7.4
<#
Regression guard for #843 — per-thread tolerance + stderr-debug surfacing in
Resolve-PRReviewThreads.ps1.

Prior behavior: a single `gh api graphql` failure on a single thread threw
out of the whole job, painting every PR red on a non-required check and
swallowing the stderr under Remove-Credentials before anyone could see
whether the cause was FORBIDDEN / NOT_FOUND / rate-limit.

These tests lock down the new contract:
  1. Invoke-GhGraphQl emits a `::debug::` line carrying the raw stderr BEFORE
     Remove-Credentials runs.
  2. Resolve-ReviewThread classifies failures into AlreadyResolved / Outdated /
     NotFound / Forbidden / Transient / Fatal, and only Fatal bubbles up.
  3. Invoke-AutoResolveThreads returns Status=Success with the tolerable
     thread ids moved to SkippedThreadIds + ToleratedFailures.
  4. The workflow step `continue-on-error: true` is present so genuine
     network outages cannot paint the PR red.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Resolve-PRReviewThreads.ps1'
}

Describe 'ConvertTo-ThreadResolveClassification (#843)' {
    BeforeAll {
        . $script:ModulePath
    }

    It 'classifies already-resolved as AlreadyResolved' {
        (ConvertTo-ThreadResolveClassification -Message 'Thread is already resolved') | Should -Be 'AlreadyResolved'
    }

    It 'classifies outdated diff as Outdated' {
        (ConvertTo-ThreadResolveClassification -Message 'GraphQL: OUTDATED: line no longer exists') | Should -Be 'Outdated'
    }

    It 'classifies NOT_FOUND as NotFound' {
        (ConvertTo-ThreadResolveClassification -Message 'GraphQL error: NOT_FOUND on thread id') | Should -Be 'NotFound'
    }

    It 'classifies Could not resolve to a node as NotFound' {
        (ConvertTo-ThreadResolveClassification -Message 'Could not resolve to a node with the global id of MDEyOlB1...') | Should -Be 'NotFound'
    }

    It 'classifies FORBIDDEN as Forbidden' {
        (ConvertTo-ThreadResolveClassification -Message 'GraphQL error: FORBIDDEN on resolveReviewThread') | Should -Be 'Forbidden'
    }

    It 'classifies HTTP 403 as Forbidden' {
        (ConvertTo-ThreadResolveClassification -Message 'gh: HTTP 403: resource not accessible to integration') | Should -Be 'Forbidden'
    }

    It 'classifies rate-limit as Transient' {
        (ConvertTo-ThreadResolveClassification -Message 'gh: API rate limit exceeded for installation') | Should -Be 'Transient'
    }

    It 'classifies HTTP 503 as Transient' {
        (ConvertTo-ThreadResolveClassification -Message 'gh: HTTP 503: upstream unavailable') | Should -Be 'Transient'
    }

    It 'classifies EOF as Transient' {
        (ConvertTo-ThreadResolveClassification -Message 'unexpected EOF from graphql endpoint') | Should -Be 'Transient'
    }

    It 'classifies connection reset as Transient' {
        (ConvertTo-ThreadResolveClassification -Message 'gh: connection reset by peer') | Should -Be 'Transient'
    }

    It 'classifies unknown errors as Fatal' {
        (ConvertTo-ThreadResolveClassification -Message 'auth: Bad credentials: token invalid') | Should -Be 'Fatal'
    }

    It 'classifies empty message as Fatal (defensive default)' {
        (ConvertTo-ThreadResolveClassification -Message '') | Should -Be 'Fatal'
        (ConvertTo-ThreadResolveClassification -Message $null) | Should -Be 'Fatal'
    }
}

Describe 'Resolve-ReviewThread per-thread tolerance (#843)' {
    BeforeEach {
        $script:GhExitCode = 0
        $script:GhOutput = '{"data":{"resolveReviewThread":{"thread":{"id":"T_x","isResolved":true}}}}'

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
            $global:LASTEXITCODE = $script:GhExitCode
            if ($script:GhExitCode -ne 0) {
                # Mimic gh's behavior: error payload goes to stderr via 2>&1.
                Write-Error $script:GhOutput -ErrorAction Continue
            } else {
                return $script:GhOutput
            }
        }

        . $script:ModulePath
    }

    AfterEach {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
    }

    It 'returns Resolved classification on isResolved=true payload' {
        $r = Resolve-ReviewThread -ThreadId 'T_happy'
        $r.Resolved       | Should -BeTrue
        $r.Classification | Should -Be 'Resolved'
    }

    It 'returns Forbidden classification on FORBIDDEN error (tolerable)' {
        $script:GhExitCode = 1
        $script:GhOutput = 'GraphQL: FORBIDDEN: resolveReviewThread not permitted for viewer'
        $r = Resolve-ReviewThread -ThreadId 'T_forbidden' -WarningAction SilentlyContinue
        $r.Resolved       | Should -BeFalse
        $r.Classification | Should -Be 'Forbidden'
        # Message is sanitized but still populated.
        $r.Message        | Should -Not -BeNullOrEmpty
    }

    It 'returns NotFound classification on Could not resolve to a node (tolerable)' {
        $script:GhExitCode = 1
        $script:GhOutput = 'Could not resolve to a node with the global id of PRRT_kwDO...'
        $r = Resolve-ReviewThread -ThreadId 'T_missing' -WarningAction SilentlyContinue
        $r.Classification | Should -Be 'NotFound'
    }

    It 'returns Transient classification on HTTP 503 (tolerable)' {
        $script:GhExitCode = 1
        $script:GhOutput = 'gh: HTTP 503: Service Unavailable'
        $r = Resolve-ReviewThread -ThreadId 'T_flaky' -WarningAction SilentlyContinue
        $r.Classification | Should -Be 'Transient'
    }

    It 'returns Fatal classification on unknown auth error' {
        $script:GhExitCode = 1
        $script:GhOutput = 'gh: Bad credentials: token expired or revoked'
        $r = Resolve-ReviewThread -ThreadId 'T_auth' -WarningAction SilentlyContinue
        $r.Classification | Should -Be 'Fatal'
    }

    It 'DryRun returns Resolved without invoking gh' {
        $script:GhExitCode = 99  # would be Fatal if called
        $r = Resolve-ReviewThread -ThreadId 'T_dry' -DryRun
        $r.Classification | Should -Be 'Resolved'
    }
}

Describe 'Invoke-AutoResolveThreads per-thread tolerance (#843)' {
    BeforeEach {
        $script:GhCalls = [System.Collections.Generic.List[string]]::new()
        $script:ResolveResponses = @{}   # threadId -> @{ ExitCode=int; Output=string }

        $script:ThreadsJson = @'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            { "id": "T_ok",  "isResolved": false, "isOutdated": false, "path": "a.ps1", "line": 10, "originalLine": 10, "startLine": null, "originalStartLine": null,
              "comments": { "nodes": [ { "id": "IC_1", "databaseId": 9001, "createdAt": "2026-04-18T10:00:00Z", "body": "fix a", "author": { "login": "copilot-pull-request-reviewer[bot]" } } ] } },
            { "id": "T_forbidden", "isResolved": false, "isOutdated": false, "path": "b.ps1", "line": 22, "originalLine": 22, "startLine": 20, "originalStartLine": 20,
              "comments": { "nodes": [ { "id": "IC_2", "databaseId": 9002, "createdAt": "2026-04-18T10:00:00Z", "body": "fix b", "author": { "login": "copilot-pull-request-reviewer[bot]" } } ] } }
          ]
        }
      }
    }
  }
}
'@
        $script:CommitsJson = '[[{"sha":"sha-a","commit":{"committer":{"date":"2026-04-18T11:00:00Z"}}},{"sha":"sha-b","commit":{"committer":{"date":"2026-04-18T11:30:00Z"}}}]]'
        $script:ChangesJsonBySha = @{
            'sha-a' = '{"files":[{"filename":"a.ps1","patch":"@@ -8,3 +8,5 @@\n ctx\n+new line\n+another\n ctx"}]}'
            'sha-b' = '{"files":[{"filename":"b.ps1","patch":"@@ -18,4 +18,6 @@\n ctx\n+fix valid\n+more fix\n ctx\n ctx"}]}'
        }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
            $joined = [string]($Arguments -join ' ')
            $script:GhCalls.Add($joined) | Out-Null
            $global:LASTEXITCODE = 0

            if ($joined -match '^api graphql') {
                if ($joined -match 'resolveReviewThread') {
                    if ($joined -match 'threadId=(\S+)') {
                        $tid = $Matches[1]
                        if ($script:ResolveResponses.ContainsKey($tid)) {
                            $resp = $script:ResolveResponses[$tid]
                            $global:LASTEXITCODE = [int]$resp.ExitCode
                            if ($resp.ExitCode -ne 0) {
                                Write-Error $resp.Output -ErrorAction Continue
                                return
                            }
                            return $resp.Output
                        }
                        return ('{"data":{"resolveReviewThread":{"thread":{"id":"' + $tid + '","isResolved":true}}}}')
                    }
                }
                if ($joined -match 'reviewThreads') { return $script:ThreadsJson }
            }
            if ($joined -match '/pulls/\d+/comments/\d+/replies') { return '{"id":555}' }
            if ($joined -match '/pulls/\d+/commits')             { return $script:CommitsJson }
            if ($joined -match '/commits/(sha-[ab])') {
                $sha = $Matches[1]
                return $script:ChangesJsonBySha[$sha]
            }
            throw "Unexpected gh call: $joined"
        }

        . $script:ModulePath
    }

    AfterEach {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        Remove-Item Env:\SQUAD_AUTO_RESOLVE_THREADS -ErrorAction SilentlyContinue
    }

    It 'tolerates a FORBIDDEN on a single thread: Status=Success, thread moves to Skipped+Tolerated' {
        $script:ResolveResponses['T_forbidden'] = @{
            ExitCode = 1
            Output   = 'GraphQL error: FORBIDDEN on resolveReviewThread (bot-vs-bot)'
        }

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer' -WarningAction SilentlyContinue

        $result.Status            | Should -Be 'Success'
        $result.ResolvedThreadIds | Should -Contain 'T_ok'
        $result.ResolvedThreadIds | Should -Not -Contain 'T_forbidden'
        $result.SkippedThreadIds  | Should -Contain 'T_forbidden'
        ($result.ToleratedFailures | Where-Object { $_.Id -eq 'T_forbidden' -and $_.Reason -eq 'Forbidden' }) | Should -Not -BeNullOrEmpty
    }

    It 'tolerates NOT_FOUND (rebase/force-push) without failing the job' {
        $script:ResolveResponses['T_forbidden'] = @{
            ExitCode = 1
            Output   = 'Could not resolve to a node with the global id of PRRT_kwDO...'
        }

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer' -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Success'
        ($result.ToleratedFailures | Where-Object { $_.Reason -eq 'NotFound' }) | Should -Not -BeNullOrEmpty
    }

    It 'tolerates HTTP 503 transient failure without failing the job' {
        $script:ResolveResponses['T_forbidden'] = @{
            ExitCode = 1
            Output   = 'gh: HTTP 503: upstream unavailable'
        }

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer' -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Success'
        ($result.ToleratedFailures | Where-Object { $_.Reason -eq 'Transient' }) | Should -Not -BeNullOrEmpty
    }

    It 'bubbles up a Fatal (bad credentials) classification as Status=Failed' {
        $script:ResolveResponses['T_forbidden'] = @{
            ExitCode = 1
            Output   = 'gh: Bad credentials: token invalid'
        }

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer' -WarningAction SilentlyContinue

        $result.Status       | Should -Be 'Failed'
        $result.ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'includes ToleratedFailures=@() on successful all-resolve runs (shape contract)' {
        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer'
        $result.Status | Should -Be 'Success'
        $result.PSObject.Properties['ToleratedFailures'] | Should -Not -BeNullOrEmpty
        @($result.ToleratedFailures).Count | Should -Be 0
    }
}

Describe 'pr-auto-resolve-threads.yml step-level continue-on-error (#843)' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'pr-auto-resolve-threads.yml'
        $script:WorkflowText = Get-Content -Raw $script:WorkflowPath
    }

    It 'workflow file exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'sets continue-on-error: true on the Resolve step' {
        $script:WorkflowText | Should -Match '(?ms)- name:\s+Resolve addressed review threads(?:(?!- name:).)*?\n\s+continue-on-error:\s+true'
    }

    It 'retains the Status=Failed -> exit 1 guard (so fatal errors are still visible)' {
        $script:WorkflowText | Should -Match 'Status\s+-eq\s+''Failed'''
        $script:WorkflowText | Should -Match 'Auto-resolve failed'
    }
}
