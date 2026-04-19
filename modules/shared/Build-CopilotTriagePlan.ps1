#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PlanHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object[]] $Findings = @()
    )

    $parts = foreach ($f in @($Findings)) {
        $id = [string]$f.Id
        $body = [string]$f.Body
        "$id`n$body"
    }
    $normalized = ($parts | Sort-Object) -join "`n---`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

function Normalize-CopilotCategory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Category = ''
    )

    $c = $Category.Trim().ToLowerInvariant()
    if ($c -in @('blocker', 'correctness', 'security', 'style', 'nit')) {
        return $c
    }
    return 'correctness'
}

function Build-CopilotTriagePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object[]] $Findings = @(),
        [AllowNull()]
        [object] $DiffContext = $null
    )

    $dedupe = @{}
    foreach ($f in @($Findings)) {
        if ($null -eq $f) { continue }
        $category = Normalize-CopilotCategory -Category ([string]$f.Category)
        $path = [string]$f.Path
        $line = if ($null -eq $f.Line) { '' } else { [string]$f.Line }
        $body = ([string]$f.Body).Trim()
        $threadId = [string]$f.ThreadId
        $key = "$category|$threadId|$path|$line|$body"
        if ($dedupe.ContainsKey($key)) { continue }

        $clone = [ordered]@{
            Id                = [string]$f.Id
            Path              = $path
            Line              = $f.Line
            Body              = [string]$f.Body
            Category          = $category
            Severity          = [string]$f.Severity
            ThreadId          = $threadId
            IsResolved        = [bool]$f.IsResolved
            IsOutdated        = [bool]$f.IsOutdated
            CommentDatabaseId = [string]$f.CommentDatabaseId
            HasRejectionReply = [bool]$f.HasRejectionReply
        }
        $dedupe[$key] = [pscustomobject]$clone
    }

    $normalizedFindings = @($dedupe.Values | Sort-Object Category, Path, Line, Id)
    $categories = @('blocker', 'correctness', 'security', 'style', 'nit')
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($category in $categories) {
        $groupItems = @($normalizedFindings | Where-Object { $_.Category -eq $category })
        if ($groupItems.Count -eq 0) { continue }
        $items.Add([pscustomobject]@{
                Category    = $category
                Count       = $groupItems.Count
                Findings    = @($groupItems)
                DiffContext = $DiffContext
            }) | Out-Null
    }

    $threadStates = @{}
    foreach ($f in $normalizedFindings) {
        if ([string]::IsNullOrWhiteSpace([string]$f.ThreadId)) { continue }
        if (-not $threadStates.ContainsKey($f.ThreadId)) {
            $threadStates[$f.ThreadId] = [pscustomobject]@{
                ThreadId          = [string]$f.ThreadId
                IsResolved        = [bool]$f.IsResolved
                HasRejectionReply = [bool]$f.HasRejectionReply
                CommentDatabaseId = [string]$f.CommentDatabaseId
                Category          = [string]$f.Category
            }
            continue
        }

        # Once true, stays true.
        if ([bool]$f.IsResolved) { $threadStates[$f.ThreadId].IsResolved = $true }
        if ([bool]$f.HasRejectionReply) { $threadStates[$f.ThreadId].HasRejectionReply = $true }
        if ([string]::IsNullOrWhiteSpace([string]$threadStates[$f.ThreadId].CommentDatabaseId) -and
            -not [string]::IsNullOrWhiteSpace([string]$f.CommentDatabaseId)) {
            $threadStates[$f.ThreadId].CommentDatabaseId = [string]$f.CommentDatabaseId
        }
    }

    $unaddressed = @($threadStates.Values | Where-Object { -not $_.IsResolved -and -not $_.HasRejectionReply } | Sort-Object ThreadId)

    $planHash = Get-PlanHash -Findings $normalizedFindings
    $summary = [pscustomobject]@{
        TotalFindings               = $normalizedFindings.Count
        CategoryCounts              = [pscustomobject]@{
            blocker     = (@($normalizedFindings | Where-Object Category -eq 'blocker')).Count
            correctness = (@($normalizedFindings | Where-Object Category -eq 'correctness')).Count
            security    = (@($normalizedFindings | Where-Object Category -eq 'security')).Count
            style       = (@($normalizedFindings | Where-Object Category -eq 'style')).Count
            nit         = (@($normalizedFindings | Where-Object Category -eq 'nit')).Count
        }
        CopilotThreadStates         = @($threadStates.Values | Sort-Object ThreadId)
        UnaddressedCopilotThreads   = @($unaddressed)
        AllCopilotThreadsAddressed  = ($unaddressed.Count -eq 0)
    }

    [pscustomobject]@{
        PlanHash = $planHash
        Items    = @($items)
        Summary  = $summary
    }
}

