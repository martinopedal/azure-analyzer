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

$script:AutoResolveMarker = '<!-- squad-auto-resolve-thread -->'

function Resolve-RepoOwnerName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Repo)

    $parts = $Repo.Split('/', 2, [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -ne 2) {
        throw "Repo must be in owner/name format. Received: '$Repo'"
    }
    [PSCustomObject]@{ Owner = $parts[0]; Name = $parts[1] }
}

function Invoke-GhGraphQl {
    <#
        Thin wrapper around `gh api graphql`. Returns a parsed PSObject.
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

    $stdout = & gh @ghArgs 2>&1
    $exitCode = 0
    $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }

    $text = ($stdout | Out-String)
    if ($exitCode -ne 0) {
        throw "gh api graphql failed: $(Remove-Credentials $text)"
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text | ConvertFrom-Json -ErrorAction Stop
}

function Get-PRReviewThreads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $PRNumber,
        [Parameter(Mandatory)][string] $Repo
    )

    $r = Resolve-RepoOwnerName -Repo $Repo
    $query = @'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          comments(first: 10) {
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

    $resp = Invoke-GhGraphQl -Query $query -Fields @{
        owner  = $r.Owner
        name   = $r.Name
        number = $PRNumber
    }

    if (-not $resp) { return @() }
    $nodes = @($resp.data.repository.pullRequest.reviewThreads.nodes)

    $threads = foreach ($n in $nodes) {
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
    $stdout = & gh api $endpoint --paginate --slurp 2>&1
    $exitCode = 0
    $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }
    if ($exitCode -ne 0) {
        throw "gh api $endpoint failed: $(Remove-Credentials ($stdout | Out-String))"
    }

    $text = ($stdout | Out-String)
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
    $stdout = & gh api $endpoint 2>&1
    $exitCode = 0
    $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }
    if ($exitCode -ne 0) {
        throw "gh api $endpoint failed: $(Remove-Credentials ($stdout | Out-String))"
    }

    $payload = ($stdout | Out-String) | ConvertFrom-Json -ErrorAction Stop
    $map = @{}
    if (-not $payload.PSObject.Properties['files']) { return $map }
    foreach ($f in @($payload.files)) {
        $path = [string]$f.filename
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not $map.ContainsKey($path)) { $map[$path] = @() }

        $patch = ''
        if ($f.PSObject.Properties['patch']) { $patch = [string]$f.patch }
        if ([string]::IsNullOrWhiteSpace($patch)) {
            # Renames or binary diffs: assume the whole file was touched.
            $map[$path] += , @(1, [int]::MaxValue)
            continue
        }

        foreach ($line in ($patch -split "`n")) {
            if ($line -match '^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@') {
                $start = [int]$Matches[1]
                $count = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
                if ($count -lt 1) { $count = 1 }
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ThreadId,
        [switch] $DryRun
    )

    if ($DryRun) {
        Write-Verbose "DryRun: would resolve thread $ThreadId"
        return $true
    }

    $mutation = @'
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}
'@
    $resp = Invoke-GhGraphQl -Query $mutation -Fields @{ threadId = $ThreadId }
    [bool]($resp -and $resp.data.resolveReviewThread.thread.isResolved)
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
    $stdout = & gh api --method POST $endpoint -f "body=$body" 2>&1
    $exitCode = 0
    $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($exitCodeVar) { $exitCode = [int]$exitCodeVar.Value }
    if ($exitCode -ne 0) {
        Write-Warning "Failed to post resolution reply: $(Remove-Credentials ($stdout | Out-String))"
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
                ErrorMessage      = $null
            }
        }

        $earliest = ($open | Sort-Object CreatedAt | Select-Object -First 1).CreatedAt
        $allCommits = Get-PRCommitsAfter -PRNumber $PRNumber -Repo $Repo -AfterIso $earliest

        $resolved = [System.Collections.Generic.List[string]]::new()
        $skipped = [System.Collections.Generic.List[string]]::new()

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

            $ok = Resolve-ReviewThread -ThreadId $thread.Id -DryRun:$DryRun
            if (-not $ok) {
                $skipped.Add($thread.Id) | Out-Null
                continue
            }

            $hasFirstComment = $thread.Comments -and $thread.Comments.Count -gt 0
            if ($hasFirstComment -and $thread.Comments[0].PSObject.Properties['databaseId'] -and $null -ne $thread.Comments[0].databaseId) {
                Add-ResolutionReply -PRNumber $PRNumber -Repo $Repo `
                    -InReplyToCommentDatabaseId ([string]$thread.Comments[0].databaseId) `
                    -Sha $check.Sha -DryRun:$DryRun | Out-Null
            }
            $resolved.Add($thread.Id) | Out-Null
        }

        [PSCustomObject]@{
            Status            = 'Success'
            ResolvedThreadIds = @($resolved)
            SkippedThreadIds  = @($skipped)
            ErrorMessage      = $null
        }
    } catch {
        $msg = Remove-Credentials ([string]$_.Exception.Message)
        Write-Warning "Invoke-AutoResolveThreads failed: $msg"
        [PSCustomObject]@{
            Status            = 'Failed'
            ResolvedThreadIds = @()
            SkippedThreadIds  = @()
            ErrorMessage      = $msg
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($PRNumber -lt 1) {
        throw 'PRNumber is required when running Resolve-PRReviewThreads.ps1 directly.'
    }
    $result = Invoke-AutoResolveThreads -PRNumber $PRNumber -Repo $Repo -DryRun:$DryRun
    $result | ConvertTo-Json -Depth 5
    if ($result.Status -eq 'Failed') { exit 1 }
}
