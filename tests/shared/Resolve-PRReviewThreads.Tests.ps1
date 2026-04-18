#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Resolve-PRReviewThreads.ps1'
}

Describe 'Resolve-PRReviewThreads helper' {

    BeforeEach {
        $script:GhCalls = [System.Collections.Generic.List[string]]::new()
        $script:ResolvedThreadIds = [System.Collections.Generic.List[string]]::new()
        $script:RepliedToCommentIds = [System.Collections.Generic.List[string]]::new()

        # Three review threads, all created at 10:00. Files: a.ps1, b.ps1, c.ps1.
        # Two commits land at 11:00/11:30: one touches a.ps1 line 10 (matches t1),
        # one touches b.ps1 line 22 (matches t2). Nothing touches c.ps1, so t3
        # must stay open.
        $script:ThreadsJson = @'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            {
              "id": "T_t1",
              "isResolved": false,
              "isOutdated": false,
              "path": "a.ps1",
              "line": 10,
              "originalLine": 10,
              "startLine": null,
              "originalStartLine": null,
              "comments": { "nodes": [
                { "id": "IC_c1", "databaseId": 9001, "createdAt": "2026-04-18T10:00:00Z", "body": "fix validation", "author": { "login": "copilot-pull-request-reviewer[bot]" } }
              ] }
            },
            {
              "id": "T_t2",
              "isResolved": false,
              "isOutdated": false,
              "path": "b.ps1",
              "line": 22,
              "originalLine": 22,
              "startLine": 20,
              "originalStartLine": 20,
              "comments": { "nodes": [
                { "id": "IC_c2", "databaseId": 9002, "createdAt": "2026-04-18T10:00:00Z", "body": "use Remove-Credentials", "author": { "login": "copilot-pull-request-reviewer[bot]" } }
              ] }
            },
            {
              "id": "T_t3",
              "isResolved": false,
              "isOutdated": false,
              "path": "c.ps1",
              "line": 5,
              "originalLine": 5,
              "startLine": null,
              "originalStartLine": null,
              "comments": { "nodes": [
                { "id": "IC_c3", "databaseId": 9003, "createdAt": "2026-04-18T10:00:00Z", "body": "extract helper", "author": { "login": "human-reviewer" } }
              ] }
            }
          ]
        }
      }
    }
  }
}
'@

        $script:CommitsJson = '[[{"sha":"sha-fix-a","commit":{"committer":{"date":"2026-04-18T11:00:00Z"}}},{"sha":"sha-fix-b","commit":{"committer":{"date":"2026-04-18T11:30:00Z"}}}]]'

        $script:ChangesJsonBySha = @{
            'sha-fix-a' = '{"files":[{"filename":"a.ps1","patch":"@@ -8,3 +8,5 @@\n ctx\n+new line\n+another\n ctx"}]}'
            'sha-fix-b' = '{"files":[{"filename":"b.ps1","patch":"@@ -18,4 +18,6 @@\n ctx\n+fix valid\n+more fix\n ctx\n ctx"}]}'
        }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
            $joined = [string]($Arguments -join ' ')
            $script:GhCalls.Add($joined) | Out-Null

            if ($joined -match '^api graphql') {
                if ($joined -match 'resolveReviewThread') {
                    if ($joined -match 'threadId=(\S+)') {
                        $tid = $Matches[1]
                        $script:ResolvedThreadIds.Add($tid) | Out-Null
                        return ('{"data":{"resolveReviewThread":{"thread":{"id":"' + $tid + '","isResolved":true}}}}')
                    }
                }
                if ($joined -match 'reviewThreads') {
                    return $script:ThreadsJson
                }
            }

            if ($joined -match '/pulls/\d+/comments/(\d+)/replies') {
                $script:RepliedToCommentIds.Add($Matches[1]) | Out-Null
                return '{"id":555}'
            }

            if ($joined -match '/pulls/\d+/commits') {
                return $script:CommitsJson
            }

            if ($joined -match '/commits/(sha-fix-[ab])') {
                $sha = $Matches[1]
                if ($script:ChangesJsonBySha.ContainsKey($sha)) {
                    return $script:ChangesJsonBySha[$sha]
                }
                return '{"files":[]}'
            }

            throw "Unexpected gh call: $joined"
        }

        . $script:ModulePath
    }

    AfterEach {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        Remove-Item Env:\SQUAD_AUTO_RESOLVE_THREADS -ErrorAction SilentlyContinue
    }

    It 'resolves threads whose lines were touched by post-thread commits and leaves untouched threads open' {
        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer'

        $result.Status            | Should -Be 'Success'
        $result.ResolvedThreadIds | Should -Contain 'T_t1'
        $result.ResolvedThreadIds | Should -Contain 'T_t2'
        $result.ResolvedThreadIds | Should -Not -Contain 'T_t3'
        $result.SkippedThreadIds  | Should -Contain 'T_t3'

        $script:RepliedToCommentIds | Should -Contain '9001'
        $script:RepliedToCommentIds | Should -Contain '9002'
        $script:RepliedToCommentIds | Should -Not -Contain '9003'
    }

    It 'is a no-op when SQUAD_AUTO_RESOLVE_THREADS=0' {
        $env:SQUAD_AUTO_RESOLVE_THREADS = '0'
        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer'

        $result.Status               | Should -Be 'Disabled'
        @($result.ResolvedThreadIds).Count | Should -Be 0
        @($script:ResolvedThreadIds).Count | Should -Be 0
    }

    It 'DryRun makes no resolve mutation or reply call' {
        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer' -DryRun

        $result.Status | Should -Be 'Success'
        (@($result.ResolvedThreadIds).Count + @($result.SkippedThreadIds).Count) | Should -Be 3
        @($script:GhCalls | Where-Object { $_ -match 'resolveReviewThread' }).Count | Should -Be 0
        @($script:GhCalls | Where-Object { $_ -match '/replies' }).Count            | Should -Be 0
    }

    It 'skips deletion-only hunks (@@ +c,0 @@) and does not match overlapping threads' {
        # Override the per-commit changes: sha-fix-a now reports a
        # deletion-only hunk on a.ps1 at line 10 (count=0). Previously this
        # would have fabricated a +10,1 range and falsely matched thread t1.
        $script:ChangesJsonBySha['sha-fix-a'] = '{"files":[{"filename":"a.ps1","patch":"@@ -8,3 +10,0 @@\n-removed\n-also removed\n-and this"}]}'

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer'

        $result.Status            | Should -Be 'Success'
        # t1 must NOT be auto-resolved: the only matching commit was a deletion-only hunk.
        $result.ResolvedThreadIds | Should -Not -Contain 'T_t1'
        $result.SkippedThreadIds  | Should -Contain 'T_t1'
        # t2 (real +18,6 hunk on b.ps1) must still resolve.
        $result.ResolvedThreadIds | Should -Contain 'T_t2'
    }

    It 'skips files with missing patch (binary/rename/oversized) instead of marking the whole file as touched' {
        # sha-fix-a now arrives with NO patch field on a.ps1 (binary, rename,
        # or oversized diff). Previously the resolver assumed the whole file
        # was touched and would auto-resolve t1 even though we have no
        # line-level evidence.
        $script:ChangesJsonBySha['sha-fix-a'] = '{"files":[{"filename":"a.ps1","status":"renamed","previous_filename":"old-a.ps1"}]}'

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer' -WarningAction SilentlyContinue

        $result.Status            | Should -Be 'Success'
        $result.ResolvedThreadIds | Should -Not -Contain 'T_t1'
        $result.SkippedThreadIds  | Should -Contain 'T_t1'
        $result.ResolvedThreadIds | Should -Contain 'T_t2'
    }

    It 'paginates reviewThreads until hasNextPage is false' {
        # Simulate two pages of review threads. Page 1 contains t1+t2 plus
        # hasNextPage=true; page 2 contains an extra thread on a.ps1 that
        # should also resolve via sha-fix-a's +8,5 hunk.
        $script:Page1Json = @'
{
  "data": { "repository": { "pullRequest": { "reviewThreads": {
    "pageInfo": { "hasNextPage": true, "endCursor": "CURSOR_PAGE_2" },
    "nodes": [
      {"id":"T_t1","isResolved":false,"isOutdated":false,"path":"a.ps1","line":10,"originalLine":10,"startLine":null,"originalStartLine":null,
       "comments":{"nodes":[{"id":"IC_c1","databaseId":9001,"createdAt":"2026-04-18T10:00:00Z","body":"fix validation","author":{"login":"copilot-pull-request-reviewer[bot]"}}]}},
      {"id":"T_t2","isResolved":false,"isOutdated":false,"path":"b.ps1","line":22,"originalLine":22,"startLine":20,"originalStartLine":20,
       "comments":{"nodes":[{"id":"IC_c2","databaseId":9002,"createdAt":"2026-04-18T10:00:00Z","body":"use Remove-Credentials","author":{"login":"copilot-pull-request-reviewer[bot]"}}]}}
    ]
  }}}}
}
'@
        $script:Page2Json = @'
{
  "data": { "repository": { "pullRequest": { "reviewThreads": {
    "pageInfo": { "hasNextPage": false, "endCursor": null },
    "nodes": [
      {"id":"T_t4","isResolved":false,"isOutdated":false,"path":"a.ps1","line":9,"originalLine":9,"startLine":null,"originalStartLine":null,
       "comments":{"nodes":[{"id":"IC_c4","databaseId":9004,"createdAt":"2026-04-18T10:00:00Z","body":"page-2 thread","author":{"login":"human-reviewer"}}]}}
    ]
  }}}}
}
'@

        # Re-define gh to return paginated thread results.
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
            $joined = [string]($Arguments -join ' ')
            $script:GhCalls.Add($joined) | Out-Null

            if ($joined -match '^api graphql') {
                if ($joined -match 'resolveReviewThread') {
                    if ($joined -match 'threadId=(\S+)') {
                        $tid = $Matches[1]
                        $script:ResolvedThreadIds.Add($tid) | Out-Null
                        return ('{"data":{"resolveReviewThread":{"thread":{"id":"' + $tid + '","isResolved":true}}}}')
                    }
                }
                if ($joined -match 'reviewThreads') {
                    if ($joined -match 'cursor=CURSOR_PAGE_2') { return $script:Page2Json }
                    return $script:Page1Json
                }
            }
            if ($joined -match '/pulls/\d+/comments/(\d+)/replies') {
                $script:RepliedToCommentIds.Add($Matches[1]) | Out-Null
                return '{"id":555}'
            }
            if ($joined -match '/pulls/\d+/commits') { return $script:CommitsJson }
            if ($joined -match '/commits/(sha-fix-[ab])') {
                $sha = $Matches[1]
                if ($script:ChangesJsonBySha.ContainsKey($sha)) { return $script:ChangesJsonBySha[$sha] }
                return '{"files":[]}'
            }
            throw "Unexpected gh call: $joined"
        }

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer'

        $result.Status            | Should -Be 'Success'
        # Both pages must have been fetched.
        @($script:GhCalls | Where-Object { $_ -match 'reviewThreads' }).Count | Should -BeGreaterOrEqual 2
        @($script:GhCalls | Where-Object { $_ -match 'cursor=CURSOR_PAGE_2' }).Count | Should -Be 1
        # Page-2 thread must be visible to the resolver and resolved (line 9 is in the +8,5 hunk).
        $result.ResolvedThreadIds | Should -Contain 'T_t4'
    }

    It 'skips posting a reply when the auto-resolve marker is already present (idempotency)' {
        # Override threads JSON: t1's first comment already carries a sibling
        # comment with the marker (simulating a prior overlapping run that
        # already replied). The resolveReviewThread mutation may still fire
        # (server-side idempotent), but the reply POST MUST be skipped to
        # avoid duplicate marker comments.
        $script:ThreadsJson = @'
{
  "data": { "repository": { "pullRequest": { "reviewThreads": {
    "pageInfo": { "hasNextPage": false, "endCursor": null },
    "nodes": [
      {"id":"T_t1","isResolved":false,"isOutdated":false,"path":"a.ps1","line":10,"originalLine":10,"startLine":null,"originalStartLine":null,
       "comments":{"nodes":[
         {"id":"IC_c1","databaseId":9001,"createdAt":"2026-04-18T10:00:00Z","body":"fix validation","author":{"login":"copilot-pull-request-reviewer[bot]"}},
         {"id":"IC_c1b","databaseId":9101,"createdAt":"2026-04-18T11:05:00Z","body":"<!-- squad-auto-resolve-thread -->\n_Auto-resolved by squad: addressed in `sha-fix-a` (follow-up commit modified the flagged lines)._","author":{"login":"github-actions[bot]"}}
       ]}}
    ]
  }}}}
}
'@

        $result = Invoke-AutoResolveThreads -PRNumber 142 -Repo 'martinopedal/azure-analyzer'

        $result.Status            | Should -Be 'Success'
        $result.ResolvedThreadIds | Should -Contain 'T_t1'
        # No new reply must have been posted to comment 9001 in this run.
        $script:RepliedToCommentIds | Should -Not -Contain '9001'
        @($script:GhCalls | Where-Object { $_ -match '/replies' }).Count | Should -Be 0
    }
}
