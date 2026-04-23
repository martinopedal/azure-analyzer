#Requires -Version 7.4
<#
.SYNOPSIS
    Auto-resolves PR review threads when a follow-up commit modifies the
    file/line range the reviewer flagged.

.DESCRIPTION
    Implements issue #106. After a squad agent pushes a fix in response to a
    Copilot or human review comment, threads whose path + line range were
    touched by commits added AFTER the thread was created are resolved via
    the GitHub GraphQL `resolveReviewThread` mutation. A short reply comment
    is posted on each resolved thread linking the addressing commit SHA.

    Threads that the new commits did NOT touch stay open - the reviewer
    decides. This is the conservative half of the auto-resolve contract:
    explanation-only replies still need manual resolution.

    Designed to be dot-sourced from a workflow step or invoked directly:

        ./modules/shared/Resolve-PRReviewThreads.ps1 -PRNumber 142

    Disable via env var: SQUAD_AUTO_RESOLVE_THREADS=0
#>
[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int] $PRNumber = 0,

    [ValidateNotNullOrEmpty()]
    [string] $Repo = 'martinopedal/azure-analyzer',

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Sanitize.ps1')
. (Join-Path $PSScriptRoot 'Retry.ps1')
$errorsPath = Join-Path $PSScriptRoot 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }

$script:AutoResolveMarker = '<!-- squad-auto-resolve-thread -->'

function Resolve-RepoOwnerName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Repo)

    $parts = $Repo.Split('/', 2, [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -ne 2) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:Resolve-PRReviewThreads' `
            -Category 'InvalidParameter' `
            -Reason "Repo must be in owner/name format. Received: '$Repo'" `
            -Remediation "Pass -Repo as 'owner/name' (e.g. 'martinopedal/azure-analyzer')."))
    }
    [PSCustomObject]@{ Owner = $parts[0]; Name = $parts[1] }
}

function Invoke-GhGraphQl {
    <#
        Thin wrapper around `gh api graphql`. Returns a parsed PSObject.

        Stderr visibility contract (#843):
        When `gh api graphql` exits non-zero we emit the UNSANITIZED stderr
        to the Actions log as a `::debug::` annotation BEFORE running
        Remove-Credentials. GitHub Actions auto-masks registered secrets in
        `::debug::` output, so tokens remain redacted while the underlying
        error payload (FORBIDDEN / NOT_FOUND / RESOLVED / rate-limit JSON)
        becomes visible to maintainers debugging auto-resolve failures.
        The thrown finding-error message still carries the sanitized copy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Query,
        [hashtable] $Fields
    )

    $ghArgs = @('api', 'graphql', '-f', "query=$Query")
    if ($Fields) {
        foreach ($k in $Fields.Keys) {
            $ghArgs += @('-F', "$k=$($Fields[$k])")
        }
    }

    $text = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -ScriptBlock {
        # `gh` can be mocked as a PowerShell function in tests. In that case,
        # LASTEXITCODE is not updated and may retain a stale non-zero value
        # from an earlier native command (observed on ubuntu-latest). Reset
        # before invocation so exit handling reflects this call only.
        $global:LASTEXITCODE = 0
        $stdout = & gh @ghArgs 2>&1
        $exitCode = 0
        $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }
        $innerText = ($stdout | Out-String)
        if ($exitCode -ne 0) {
            # #843: surface the raw stderr as a debug annotation BEFORE we
            # sanitize / throw. GitHub Actions masks registered secrets in
            # ::debug:: output automatically, so this does not leak tokens.
            # Without this, the classifier loses the signal it needs to
            # decide RESOLVED / OUTDATED / FORBIDDEN / NOT_FOUND.
            $debugLine = ($innerText -replace "`r?`n", ' ⏎ ')
            Write-Host "::debug::gh api graphql exit=$exitCode raw=$debugLine"
            # #843: the classifier (and Invoke-WithRetry's transient-message
            # scan) MUST be able to see the upstream error vocabulary
            # (FORBIDDEN / NOT_FOUND / HTTP 503 / rate limit). Format-
            # FindingErrorMessage drops Details from its rendered string, so
            # we throw a plain exception whose .Message IS the sanitized
            # stderr payload. The ::debug:: annotation above preserves the
            # raw (still token-masked) stderr for maintainers.
            $sanitized = Remove-Credentials $innerText
            throw [System.Exception]::new("gh api graphql failed (exit=$exitCode): $sanitized")
        }
        $innerText
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text | ConvertFrom-Json -ErrorAction Stop
}

function ConvertTo-ThreadResolveClassification {
    <#
        Classify a `resolveReviewThread` failure message (#843).

        Returns one of:
          - 'AlreadyResolved' : thread is already resolved; idempotent skip
          - 'Outdated'        : thread attached to an outdated diff; skip
          - 'NotFound'        : thread id unknown (rebase / force-push / deletion); skip
          - 'Forbidden'       : mutation refused (bot-vs-bot fallback, app scope drift); warn + skip
          - 'Transient'       : rate-limit / 5xx / network glitch; warn + skip (retry handled upstream)
          - 'Fatal'           : anything else (auth, schema, unknown); bubble up

        The classifier scans the raw gh stderr / exception message for the
        upstream GitHub GraphQL error vocabulary.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()]
        [string] $Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return 'Fatal' }

    # Normalize for case-insensitive substring matching.
    $m = $Message

    # Already-resolved: GitHub returns either an explicit "already resolved"
    # string or the mutation succeeds idempotently with isResolved=true.
    if ($m -match '(?i)already\s+resolved' -or
        $m -match '(?i)thread\s+is\s+resolved' -or
        $m -match '(?i)"isResolved"\s*:\s*true') {
        return 'AlreadyResolved'
    }

    if ($m -match '(?i)\bOUTDATED\b' -or $m -match '(?i)outdated\s+(?:diff|thread|line)') {
        return 'Outdated'
    }

    if ($m -match '(?i)\bNOT_FOUND\b' -or
        $m -match '(?i)could\s+not\s+resolve\s+to\s+a\s+node' -or
        ($m -match '(?i)resource\s+not\s+accessible' -and $m -match '(?i)thread')) {
        return 'NotFound'
    }

    if ($m -match '(?i)\bFORBIDDEN\b' -or $m -match '(?i)HTTP\s*403') {
        return 'Forbidden'
    }

    if ($m -match '(?i)\brate\s*limit' -or
        $m -match '(?i)HTTP\s*(?:429|5\d\d)' -or
        $m -match '(?i)\btimeout\b' -or
        $m -match '(?i)\bEOF\b' -or
        $m -match '(?i)connection\s+(?:reset|refused|closed)' -or
        $m -match '(?i)broken\s+pipe') {
        return 'Transient'
    }

    return 'Fatal'
}

function Get-PRReviewThreads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $PRNumber,
        [Parameter(Mandatory)][string] $Repo
    )

    $r = Resolve-RepoOwnerName -Repo $Repo
    # Pagination (#137 gate fix, Codex-2): cursor through reviewThreads until
    # hasNextPage=false. PRs with >100 unresolved threads were silently missing
    # candidates with the previous single-page query.
    $query = @'
query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          comments(first: 100) {
            nodes {
              id
              databaseId
              createdAt
              body
              author { login }
            }
          }
        }
      }
    }
  }
}
'@

    $allNodes = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    $safetyMax = 50  # 50 * 100 = 5000 threads upper bound; defends against runaway loops.
    $iter = 0
    do {
        $fields = @{
            owner  = $r.Owner
            name   = $r.Name
            number = $PRNumber
        }
        if ($null -ne $cursor) { $fields['cursor'] = $cursor }

        $resp = Invoke-GhGraphQl -Query $query -Fields $fields
        if (-not $resp) { break }

        $page = $resp.data.repository.pullRequest.reviewThreads
        foreach ($n in @($page.nodes)) { $allNodes.Add($n) | Out-Null }

        $hasNext = $false
        if ($page.PSObject.Properties['pageInfo'] -and $page.pageInfo) {
            if ($page.pageInfo.PSObject.Properties['hasNextPage']) {
                $hasNext = [bool]$page.pageInfo.hasNextPage
            }
            if ($hasNext -and $page.pageInfo.PSObject.Properties['endCursor']) {
                $cursor = [string]$page.pageInfo.endCursor
            } else {
                $cursor = $null
            }
        }
        $iter++
        if ($iter -ge $safetyMax) {
            Write-Warning "Get-PRReviewThreads: pagination safety cap ($safetyMax pages) reached for PR #$PRNumber"
            break
        }
    } while ($hasNext -and $cursor)

    if ($allNodes.Count -eq 0) { return @() }

    $threads = foreach ($n in $allNodes) {
        $comments = @($n.comments.nodes)
        $first = if ($comments.Count -gt 0) { $comments[0] } else { $null }

        $line = $null
        if ($n.PSObject.Properties['line'] -and $null -ne $n.line) { $line = [int]$n.line }
        if ($null -eq $line -and $n.PSObject.Properties['originalLine'] -and $null -ne $n.originalLine) {
            $line = [int]$n.originalLine
        }

        $startLine = $line
        if ($n.PSObject.Properties['startLine'] -and $null -ne $n.startLine) {
            $startLine = [int]$n.startLine
        } elseif ($n.PSObject.Properties['originalStartLine'] -and $null -ne $n.originalStartLine) {
            $startLine = [int]$n.originalStartLine
        }

        [PSCustomObject]@{
            Id             = [string]$n.id
            Path           = [string]$n.path
            Line           = $line
            StartLine      = $startLine
            IsResolved     = [bool]$n.isResolved
            IsOutdated     = [bool]$n.isOutdated
            CreatedAt      = if ($first) { [string]$first.createdAt } else { $null }
            FirstCommentId = if ($first) { [string]$first.id } else { $null }
            Comments       = $comments
        }
    }

    @($threads)
}

function Get-PRCommitsAfter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $PRNumber,
        [Parameter(Mandatory)][string] $Repo,
        [string] $AfterIso
    )

    $r = Resolve-RepoOwnerName -Repo $Repo
    $endpoint = "repos/$($r.Owner)/$($r.Name)/pulls/$PRNumber/commits"
    $text = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -ScriptBlock {
        # See Invoke-GhGraphQl: reset LASTEXITCODE so function-mocked `gh`
        # in Pester does not inherit a stale non-zero from a prior native call.
        $global:LASTEXITCODE = 0
        $stdout = & gh api $endpoint --paginate --slurp 2>&1
        $exitCode = 0
        $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }
        $innerText = ($stdout | Out-String)
        if ($exitCode -ne 0) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:Resolve-PRReviewThreads' `
                -Category 'UnexpectedFailure' `
                -Reason "gh api $endpoint failed (PR commits)." `
                -Remediation 'Inspect gh stderr (sanitized in Details) and verify the GH_TOKEN scope.' `
                -Details (Remove-Credentials $innerText)))
        }
        $innerText
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $pages = @($text | ConvertFrom-Json -ErrorAction Stop)
    $afterDt = $null
    if (-not [string]::IsNullOrWhiteSpace($AfterIso)) {
        $afterDt = [System.DateTimeOffset]::Parse($AfterIso, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) {
        foreach ($c in @($page)) {
            $when = $null
            if ($c.commit -and $c.commit.committer -and $c.commit.committer.date) {
                $when = [System.DateTimeOffset]::Parse([string]$c.commit.committer.date, `
                    [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            }
            if ($null -eq $afterDt -or ($when -and $when -gt $afterDt)) {
                $out.Add([PSCustomObject]@{
                    Sha         = [string]$c.sha
                    CommittedAt = if ($when) { $when.ToString('o') } else { $null }
                })
            }
        }
    }
    @($out)
}

function Get-CommitChangedRanges {
    <#
        Returns hashtable: path -> array of [int[]] line-range tuples
        describing lines the commit touched on the RIGHT side of the diff.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Repo,
        [Parameter(Mandatory)][string] $Sha
    )

    $r = Resolve-RepoOwnerName -Repo $Repo
    $endpoint = "repos/$($r.Owner)/$($r.Name)/commits/$Sha"
    $text = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -ScriptBlock {
        # See Invoke-GhGraphQl: reset LASTEXITCODE so function-mocked `gh`
        # in Pester does not inherit a stale non-zero from a prior native call.
        $global:LASTEXITCODE = 0
        $stdout = & gh api $endpoint 2>&1
        $exitCode = 0
        $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }
        $innerText = ($stdout | Out-String)
        if ($exitCode -ne 0) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:Resolve-PRReviewThreads' `
                -Category 'UnexpectedFailure' `
                -Reason "gh api $endpoint failed (commit detail)." `
                -Remediation 'Inspect gh stderr (sanitized in Details) and verify the GH_TOKEN scope.' `
                -Details (Remove-Credentials $innerText)))
        }
        $innerText
    }

    $payload = $text | ConvertFrom-Json -ErrorAction Stop
    $map = @{}
    if (-not $payload.PSObject.Properties['files']) { return $map }
    foreach ($f in @($payload.files)) {
        $path = [string]$f.filename
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not $map.ContainsKey($path)) { $map[$path] = @() }

        $patch = ''
        if ($f.PSObject.Properties['patch']) { $patch = [string]$f.patch }
        if ([string]::IsNullOrWhiteSpace($patch)) {
            # Missing patch (#137 gate fix, Codex-1 / Goldeneye-1):
            # Renames, binary diffs, and oversized diffs all arrive without
            # `patch`. The previous behavior marked the WHOLE file as touched
            # (line 1..MaxValue), which would auto-resolve any thread on that
            # file even if the change was unrelated. Conservative path: skip
            # the file with a warning and let the thread stay open for human
            # review.
            Write-Warning "Skipping file '$path' for commit ${Sha}: no patch in API response (binary, rename, or oversized diff)."
            continue
        }

        foreach ($line in ($patch -split "`n")) {
            if ($line -match '^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@') {
                $start = [int]$Matches[1]
                # Right-side count semantics:
                #   `+c`        -> count = 1   (single added line at $start)
                #   `+c,n`      -> count = n   (n lines on the right)
                #   `+c,0`      -> count = 0   (deletion-only hunk, NO right-side range)
                # (#137 gate fix, Codex-1 / Goldeneye-1): when count is 0,
                # treat the hunk as having no right-side line range and skip
                # it entirely. The previous coercion to 1 fabricated a
                # right-side line at $start and overlap-matched threads on
                # untouched context.
                $hasCount = [bool]$Matches[2]
                if ($hasCount) {
                    $count = [int]$Matches[2]
                    if ($count -lt 1) {
                        # Deletion-only hunk: no right-side line was added or modified.
                        continue
                    }
                } else {
                    $count = 1
                }
                $end = $start + $count - 1
                $map[$path] += , @($start, $end)
            }
        }
    }
    $map
}

function Test-ThreadAddressedByCommits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject] $Thread,
        [Parameter(Mandatory)][object[]] $Commits,
        [Parameter(Mandatory)][string] $Repo
    )

    if ([string]::IsNullOrWhiteSpace($Thread.Path)) {
        return [PSCustomObject]@{ Addressed = $false; Sha = $null }
    }
    if ($null -eq $Thread.Line) {
        return [PSCustomObject]@{ Addressed = $false; Sha = $null }
    }

    $start = if ($Thread.StartLine) { [int]$Thread.StartLine } else { [int]$Thread.Line }
    $end = [int]$Thread.Line
    if ($end -lt $start) { $end = $start }

    foreach ($commit in $Commits) {
        $changes = Get-CommitChangedRanges -Repo $Repo -Sha $commit.Sha
        if (-not $changes.ContainsKey($Thread.Path)) { continue }
        foreach ($range in $changes[$Thread.Path]) {
            $rs = [int]$range[0]
            $re = [int]$range[1]
            if ($rs -le $end -and $re -ge $start) {
                return [PSCustomObject]@{ Addressed = $true; Sha = $commit.Sha }
            }
        }
    }
    [PSCustomObject]@{ Addressed = $false; Sha = $null }
}

function Resolve-ReviewThread {
    <#
        Attempt to resolve a single review thread via the GraphQL
        `resolveReviewThread` mutation.

        Returns a PSCustomObject with:
          Resolved       [bool]    true when the thread is resolved server-side (or DryRun)
          Classification [string]  one of: Resolved | AlreadyResolved | Outdated |
                                            NotFound | Forbidden | Transient | Fatal
          Message        [string]  sanitized failure message ('' on success)

        Only 'Fatal' classifications should bubble up as job-level failures;
        every other classification is a tolerable per-thread skip (#843).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ThreadId,
        [switch] $DryRun
    )

    if ($DryRun) {
        Write-Verbose "DryRun: would resolve thread $ThreadId"
        return [PSCustomObject]@{
            Resolved       = $true
            Classification = 'Resolved'
            Message        = ''
        }
    }

    $mutation = @'
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}
'@
    try {
        $resp = Invoke-GhGraphQl -Query $mutation -Fields @{ threadId = $ThreadId }
        $resolved = [bool]($resp -and $resp.data.resolveReviewThread.thread.isResolved)
        if ($resolved) {
            return [PSCustomObject]@{
                Resolved       = $true
                Classification = 'Resolved'
                Message        = ''
            }
        }
        # Mutation returned without an isResolved=true payload. Treat as
        # AlreadyResolved (idempotent) if the response mentions resolution,
        # otherwise Fatal so the caller can surface it.
        $respText = if ($resp) { ($resp | ConvertTo-Json -Depth 4 -Compress) } else { '' }
        $classification = ConvertTo-ThreadResolveClassification -Message $respText
        return [PSCustomObject]@{
            Resolved       = $false
            Classification = $classification
            Message        = (Remove-Credentials $respText)
        }
    } catch {
        $rawMsg = [string]$_.Exception.Message
        $classification = ConvertTo-ThreadResolveClassification -Message $rawMsg
        $sanitized = Remove-Credentials $rawMsg
        return [PSCustomObject]@{
            Resolved       = $false
            Classification = $classification
            Message        = $sanitized
        }
    }
}

function Add-ResolutionReply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $PRNumber,
        [Parameter(Mandatory)][string] $Repo,
        [Parameter(Mandatory)][string] $InReplyToCommentDatabaseId,
        [Parameter(Mandatory)][string] $Sha,
        [string] $Rationale = 'follow-up commit modified the flagged lines',
        [switch] $DryRun
    )

    $shortSha = if ($Sha.Length -gt 7) { $Sha.Substring(0, 7) } else { $Sha }
    $body = "$script:AutoResolveMarker`n_Auto-resolved by squad: addressed in ``$shortSha`` ($Rationale)._"

    if ($DryRun) {
        Write-Verbose "DryRun: would reply to comment $InReplyToCommentDatabaseId"
        return $true
    }

    $r = Resolve-RepoOwnerName -Repo $Repo
    $endpoint = "repos/$($r.Owner)/$($r.Name)/pulls/$PRNumber/comments/$InReplyToCommentDatabaseId/replies"
    try {
        Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -ScriptBlock {
            # See Invoke-GhGraphQl: reset LASTEXITCODE so function-mocked `gh`
            # in Pester does not inherit a stale non-zero from a prior native call.
            $global:LASTEXITCODE = 0
            $stdout = & gh api --method POST $endpoint -f "body=$body" 2>&1
            $exitCode = 0
            $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }
            if ($exitCode -ne 0) {
                throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:Resolve-PRReviewThreads' `
                    -Category 'UnexpectedFailure' `
                    -Reason 'Failed to post resolution reply.' `
                    -Remediation 'Inspect gh stderr (sanitized in Details) and verify the GH_TOKEN scope.' `
                    -Details (Remove-Credentials ($stdout | Out-String))))
            }
            $true
        } | Out-Null
    } catch {
        Write-Warning (Remove-Credentials $_.Exception.Message)
        return $false
    }
    $true
}

function Invoke-AutoResolveThreads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $PRNumber,
        [string] $Repo = 'martinopedal/azure-analyzer',
        [switch] $DryRun
    )

    if ($env:SQUAD_AUTO_RESOLVE_THREADS -eq '0') {
        return [PSCustomObject]@{
            Status            = 'Disabled'
            ResolvedThreadIds = @()
            SkippedThreadIds  = @()
            ToleratedFailures = @()
            ErrorMessage      = $null
        }
    }

    try {
        $threads = Get-PRReviewThreads -PRNumber $PRNumber -Repo $Repo
        $open = @($threads | Where-Object { -not $_.IsResolved -and $_.Path -and $_.CreatedAt })

        if ($open.Count -eq 0) {
            return [PSCustomObject]@{
                Status            = 'NoOpenThreads'
                ResolvedThreadIds = @()
                SkippedThreadIds  = @()
                ToleratedFailures = @()
                ErrorMessage      = $null
            }
        }

        $earliest = ($open | Sort-Object CreatedAt | Select-Object -First 1).CreatedAt
        $allCommits = Get-PRCommitsAfter -PRNumber $PRNumber -Repo $Repo -AfterIso $earliest

        $resolved = [System.Collections.Generic.List[string]]::new()
        $skipped = [System.Collections.Generic.List[string]]::new()
        $tolerated = [System.Collections.Generic.List[pscustomobject]]::new()

        foreach ($thread in $open) {
            $threadDt = [System.DateTimeOffset]::Parse($thread.CreatedAt, `
                [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            $eligibleCommits = @($allCommits | Where-Object {
                $_.CommittedAt -and ([System.DateTimeOffset]::Parse($_.CommittedAt, `
                    [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime -gt $threadDt)
            })

            if ($eligibleCommits.Count -eq 0) {
                $skipped.Add($thread.Id) | Out-Null
                continue
            }

            $check = Test-ThreadAddressedByCommits -Thread $thread -Commits $eligibleCommits -Repo $Repo
            if (-not $check.Addressed) {
                $skipped.Add($thread.Id) | Out-Null
                continue
            }

            # #843: per-thread tolerance. Resolve-ReviewThread now returns a
            # classified result; tolerable classifications (AlreadyResolved,
            # Outdated, NotFound, Forbidden, Transient) are logged and the
            # thread moves to SkippedThreadIds. Only 'Fatal' aborts the loop.
            $attempt = Resolve-ReviewThread -ThreadId $thread.Id -DryRun:$DryRun
            $skipReason = $null
            switch ($attempt.Classification) {
                'Resolved'        { break }
                'AlreadyResolved' { $skipReason = 'AlreadyResolved'; break }
                'Outdated'        { $skipReason = 'Outdated'; break }
                'NotFound'        { $skipReason = 'NotFound'; break }
                'Forbidden'       { $skipReason = 'Forbidden'; break }
                'Transient'       { $skipReason = 'Transient'; break }
                default {
                    # 'Fatal' — propagate. This path is for auth / schema /
                    # unrecognised errors that an operator must investigate.
                    throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:Resolve-PRReviewThreads' `
                        -Category 'UnexpectedFailure' `
                        -Reason "Fatal GraphQL error resolving thread $($thread.Id)." `
                        -Remediation 'Inspect the ::debug:: gh api graphql annotation on the failing run; verify app token scope.' `
                        -Details $attempt.Message))
                }
            }
            if ($skipReason) {
                if ($skipReason -in @('Forbidden','Transient')) {
                    Write-Warning "auto-resolve skip thread=$($thread.Id) reason=$skipReason msg=$($attempt.Message)"
                } else {
                    Write-Host "::notice::auto-resolve skip thread=$($thread.Id) reason=$skipReason"
                }
                $skipped.Add($thread.Id) | Out-Null
                $tolerated.Add([pscustomobject]@{ Id = $thread.Id; Reason = $skipReason }) | Out-Null
                continue
            }

            $hasFirstComment = $thread.Comments -and $thread.Comments.Count -gt 0
            if ($hasFirstComment -and $thread.Comments[0].PSObject.Properties['databaseId'] -and $null -ne $thread.Comments[0].databaseId) {
                # Idempotency guard (#137 gate fix, Codex-3):
                # Two overlapping workflow runs can both reach this point
                # before concurrency cancellation lands. The
                # resolveReviewThread mutation is server-side idempotent on a
                # resolved thread, but the reply POST is NOT, so we'd post the
                # marker twice. Scan existing comments for our marker first
                # and skip the reply if it's already there.
                $markerAlreadyPresent = $false
                foreach ($c in $thread.Comments) {
                    if ($c -and $c.PSObject.Properties['body'] -and $c.body -and `
                        ([string]$c.body).Contains($script:AutoResolveMarker)) {
                        $markerAlreadyPresent = $true
                        break
                    }
                }
                if (-not $markerAlreadyPresent) {
                    Add-ResolutionReply -PRNumber $PRNumber -Repo $Repo `
                        -InReplyToCommentDatabaseId ([string]$thread.Comments[0].databaseId) `
                        -Sha $check.Sha -DryRun:$DryRun | Out-Null
                }
            }
            $resolved.Add($thread.Id) | Out-Null
        }

        [PSCustomObject]@{
            Status               = 'Success'
            ResolvedThreadIds    = @($resolved)
            SkippedThreadIds     = @($skipped)
            ToleratedFailures    = @($tolerated)
            ErrorMessage         = $null
        }
    } catch {
        $msg = Remove-Credentials ([string]$_.Exception.Message)
        Write-Warning "Invoke-AutoResolveThreads failed: $msg"
        [PSCustomObject]@{
            Status            = 'Failed'
            ResolvedThreadIds = @()
            SkippedThreadIds  = @()
            ToleratedFailures = @()
            ErrorMessage      = $msg
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($PRNumber -lt 1) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:Resolve-PRReviewThreads' `
            -Category 'InvalidParameter' `
            -Reason 'PRNumber is required when running Resolve-PRReviewThreads.ps1 directly.' `
            -Remediation 'Pass -PRNumber <int> to the script invocation.'))
    }
    $result = Invoke-AutoResolveThreads -PRNumber $PRNumber -Repo $Repo -DryRun:$DryRun
    $result | ConvertTo-Json -Depth 5
    if ($result.Status -eq 'Failed') { throw $result.ErrorMessage }
}
