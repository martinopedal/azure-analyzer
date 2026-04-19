#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Sanitize.ps1')
. (Join-Path $PSScriptRoot 'Retry.ps1')
. (Join-Path $PSScriptRoot 'Resolve-PRReviewThreads.ps1')

function Get-CopilotCategoryAndSeverity {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Body = ''
    )

    $category = 'correctness'
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        if ($Body -match '(?im)^\s*\[(blocker|correctness|security|style|nit)\]') {
            $category = $Matches[1].ToLowerInvariant()
        }
    }

    $severity = switch ($category) {
        'blocker'     { 'High' }
        'security'    { 'High' }
        'correctness' { 'Medium' }
        'style'       { 'Low' }
        'nit'         { 'Info' }
        default       { 'Medium' }
    }

    [pscustomobject]@{
        Category = $category
        Severity = $severity
    }
}

function Get-CopilotReviewFindings {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Owner,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Repo,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $PullNumber
    )

    $ownerName = [string]$Owner
    $repoName = [string]$Repo
    if ($repoName.Contains('/')) {
        $repoParts = $repoName.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($repoParts.Count -ge 2) {
            if ([string]::IsNullOrWhiteSpace($ownerName)) {
                $ownerName = [string]$repoParts[0]
            }
            $repoName = [string]$repoParts[$repoParts.Count - 1]
        }
    }

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
          comments(first: 100) {
            nodes {
              id
              databaseId
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

    $all = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    $hasNext = $true
    $maxPages = 50
    $page = 0

    while ($hasNext -and $page -lt $maxPages) {
        $fields = @{
            owner  = $ownerName
            name   = $repoName
            number = $PullNumber
        }
        if ($null -ne $cursor) {
            $fields['cursor'] = $cursor
        }

        $resp = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 1 -ScriptBlock {
            Invoke-GhGraphQl -Query $query -Fields $fields
        }

        if (-not $resp) { break }

        $threads = $resp.data.repository.pullRequest.reviewThreads
        foreach ($thread in @($threads.nodes)) {
            $threadHasRejectionReply = $false
            foreach ($comment in @($thread.comments.nodes)) {
                $body = [string]$comment.body
                if ($body -match '(?i)multi-model rejection') {
                    $threadHasRejectionReply = $true
                    break
                }
            }

            foreach ($comment in @($thread.comments.nodes)) {
                $login = ''
                if ($comment.author -and $comment.author.login) {
                    $login = [string]$comment.author.login
                }
                if ($login -notmatch '(?i)copilot') { continue }

                $line = $null
                if ($thread.PSObject.Properties['line'] -and $null -ne $thread.line) {
                    $line = [int]$thread.line
                } elseif ($thread.PSObject.Properties['originalLine'] -and $null -ne $thread.originalLine) {
                    $line = [int]$thread.originalLine
                }

                $cat = Get-CopilotCategoryAndSeverity -Body ([string]$comment.body)
                $findingId = "$([string]$thread.id):$([string]$comment.id)"

                $all.Add([pscustomobject]@{
                        Id               = $findingId
                        Path             = [string]$thread.path
                        Line             = $line
                        Body             = [string]$comment.body
                        Category         = [string]$cat.Category
                        Severity         = [string]$cat.Severity
                        ThreadId         = [string]$thread.id
                        IsResolved       = [bool]$thread.isResolved
                        IsOutdated       = [bool]$thread.isOutdated
                        CommentDatabaseId = if ($comment.PSObject.Properties['databaseId']) { [string]$comment.databaseId } else { $null }
                        HasRejectionReply = $threadHasRejectionReply
                    }) | Out-Null
            }
        }

        $hasNext = [bool]$threads.pageInfo.hasNextPage
        $cursor = if ($hasNext) { [string]$threads.pageInfo.endCursor } else { $null }
        $page++
    }

    @($all)
}

