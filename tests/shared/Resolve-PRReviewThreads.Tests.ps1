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
}
