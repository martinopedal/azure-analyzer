#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int] $PRNumber = 0,

    [ValidateNotNullOrEmpty()]
    [string] $Repo = 'martinopedal/azure-analyzer',

    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = '.squad/decisions/inbox/',

    [string] $ModelResponsesPath,

    [string] $Agent = 'sentinel',

    [string] $PRAuthorAgent = $env:PR_AUTHOR_AGENT,

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Sanitize.ps1')

function New-RepoTempFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Prefix
    )

    $tempDir = Join-Path $PSScriptRoot '..\..\.squad\state\tmp'
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }

    Join-Path $tempDir "$Prefix-$([guid]::NewGuid().ToString('N')).tmp"
}

function Resolve-RepoParts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Repo
    )

    $parts = $Repo.Split('/', 2, [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -ne 2) {
        throw "Repo must be in owner/name format. Received: '$Repo'"
    }

    [PSCustomObject]@{
        Owner = $parts[0]
        Name  = $parts[1]
    }
}

function Invoke-GhApiPaged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Endpoint
    )

    $stdoutPath = New-RepoTempFile -Prefix 'gh-api-out'
    $stderrPath = New-RepoTempFile -Prefix 'gh-api-err'
    $maxRetries = 3
    $lastError = ''
    $text = ''

    try {
        for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
            # `gh` can be mocked as a PowerShell function in tests. In that case,
            # LASTEXITCODE is not updated and may retain a stale non-zero value
            # from an earlier native command (observed on ubuntu-latest). Reset
            # before invocation so exit handling reflects this call only.
            $global:LASTEXITCODE = 0
            & gh api $Endpoint --paginate --slurp 1> $stdoutPath 2> $stderrPath
            $exitCode = 0
            $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            if ($exitCodeVar) {
                $exitCode = [int]$exitCodeVar.Value
            }

            if ($exitCode -eq 0) {
                break
            }

            $stderrText = ''
            if (Test-Path $stderrPath) {
                $stderrText = Get-Content -Path $stderrPath -Raw
            }

            $lastError = Remove-Credentials $stderrText
            $isRetryable = $lastError -match '(?i)(429|rate limit|503|timeout|temporar)'
            if ($isRetryable -and $attempt -lt ($maxRetries - 1)) {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                continue
            }

            throw "gh api $Endpoint failed: $lastError"
        }

        if (Test-Path $stdoutPath) {
            $text = Get-Content -Path $stdoutPath -Raw
        }
    } finally {
        Remove-Item -Path $stdoutPath -ErrorAction SilentlyContinue
        Remove-Item -Path $stderrPath -ErrorAction SilentlyContinue
    }

    if (-not [string]::IsNullOrWhiteSpace($lastError) -and [string]::IsNullOrWhiteSpace($text)) {
        throw "gh api $Endpoint failed: $lastError"
    }

    $text = Remove-Credentials $text
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    $pages = @($text | ConvertFrom-Json -ErrorAction Stop)
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) {
        foreach ($item in @($page)) {
            $items.Add($item)
        }
    }

    @($items)
}

function Get-PRReviewFeedback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $Repo
    )

    $repoParts = Resolve-RepoParts -Repo $Repo
    $basePath = "repos/$($repoParts.Owner)/$($repoParts.Name)/pulls/$PRNumber"

    $reviewsRaw = Invoke-GhApiPaged -Endpoint "$basePath/reviews"
    $lineCommentsRaw = Invoke-GhApiPaged -Endpoint "$basePath/comments"

    $reviews = foreach ($review in $reviewsRaw) {
        $reviewer = if ($review.user -and $review.user.login) { [string]$review.user.login } else { 'unknown-reviewer' }
        [PSCustomObject]@{
            Id          = [string]$review.id
            Reviewer    = $reviewer
            State       = if ($review.state) { [string]$review.state } else { 'COMMENTED' }
            Body        = Remove-Credentials ([string]$review.body)
            SubmittedAt = [string]$review.submitted_at
            CommitId    = [string]$review.commit_id
        }
    }

    $lineComments = foreach ($comment in $lineCommentsRaw) {
        $reviewer = if ($comment.user -and $comment.user.login) { [string]$comment.user.login } else { 'unknown-reviewer' }
        $inReplyToId = $null
        if ($comment.PSObject.Properties['in_reply_to_id']) {
            $inReplyToId = [string]$comment.in_reply_to_id
        }

        $reviewId = $null
        if ($comment.PSObject.Properties['pull_request_review_id']) {
            $reviewId = [string]$comment.pull_request_review_id
        }

        [PSCustomObject]@{
            Id          = [string]$comment.id
            Reviewer    = $reviewer
            Body        = Remove-Credentials ([string]$comment.body)
            Path        = [string]$comment.path
            Line        = if ($null -ne $comment.line) { [int]$comment.line } else { $null }
            Side        = [string]$comment.side
            InReplyToId = $inReplyToId
            ReviewId    = $reviewId
            SubmittedAt = if ($comment.created_at) { [string]$comment.created_at } else { [string]$comment.updated_at }
        }
    }

    $states = @($reviews | ForEach-Object { $_.State })
    $reviewerStateCounts = @{}
    foreach ($state in $states) {
        if (-not $reviewerStateCounts.ContainsKey($state)) {
            $reviewerStateCounts[$state] = 0
        }
        $reviewerStateCounts[$state]++
    }

    [PSCustomObject]@{
        Repo         = $Repo
        PRNumber     = $PRNumber
        GeneratedAt  = (Get-Date).ToUniversalTime().ToString('o')
        Reviews      = @($reviews)
        LineComments = @($lineComments)
        Summary      = [PSCustomObject]@{
            ReviewCount      = @($reviews).Count
            LineCommentCount = @($lineComments).Count
            StateCounts      = $reviewerStateCounts
        }
    }
}

function Get-TriageModels {
    [CmdletBinding()]
    param()

    # Frontier-only roster. Strict allow-list, see
    # `.copilot/copilot-instructions.md` -> "Frontier Model Roster".
    @(
        [PSCustomObject]@{ Name = 'claude-opus-4.7'; Role = 'claude-premium' }
        [PSCustomObject]@{ Name = 'gpt-5.3-codex'; Role = 'openai-codex' }
        [PSCustomObject]@{ Name = 'goldeneye'; Role = 'architectural-diversity' }
    )
}

function Invoke-MultiModelTriage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $FeedbackPayload,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [switch] $DryRun
    )

    $models = @(Get-TriageModels)
    $promptBundle = [System.Collections.Generic.List[object]]::new()
    $safeJson = Remove-Credentials ($FeedbackPayload | ConvertTo-Json -Depth 20)

    if (-not $DryRun) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    foreach ($model in $models) {
        $safeModelName = $model.Name -replace '[^A-Za-z0-9.-]', '-'
        $inputFile = Join-Path $OutputPath "pr-$($FeedbackPayload.PRNumber)-$safeModelName-feedback.json"
        $responseFile = Join-Path $OutputPath "pr-$($FeedbackPayload.PRNumber)-$safeModelName-response.json"

        $prompt = @"
You are model '$($model.Name)' in a 3-model PR review gate.
Analyze the feedback JSON file at '$inputFile'.
Return strict JSON with this schema:
{
  "reviewerVerdict": "APPROVED|CHANGES_REQUESTED|COMMENTED",
  "consensusFindings": [
    { "title": "...", "detail": "...", "path": "...", "line": 0, "severity": "Critical|High|Medium|Low" }
  ],
  "disputedFindings": [
    { "title": "...", "detail": "...", "path": "...", "line": 0, "severity": "Critical|High|Medium|Low" }
  ],
  "actionPlan": ["..."],
  "recommendedRevisionOwner": "agent-login"
}
Focus on correctness, security, lockout governance, dedup quality, and edge cases.
"@

        if (-not $DryRun) {
            Set-Content -Path $inputFile -Value $safeJson -Encoding utf8
        }

        $promptBundle.Add([PSCustomObject]@{
                Model        = $model.Name
                Role         = $model.Role
                InputFile    = $inputFile
                ResponseFile = $responseFile
                Prompt       = $prompt
            })
    }

    $bundlePath = Join-Path $OutputPath "pr-$($FeedbackPayload.PRNumber)-triage-prompt-bundle.json"
    $bundlePayload = [PSCustomObject]@{
        Repo            = $FeedbackPayload.Repo
        PRNumber        = $FeedbackPayload.PRNumber
        CreatedAt       = (Get-Date).ToUniversalTime().ToString('o')
        Status          = 'AwaitingModelResponses'
        ModelPromptPack = @($promptBundle)
    }

    if (-not $DryRun) {
        $bundleJson = Remove-Credentials ($bundlePayload | ConvertTo-Json -Depth 20)
        Set-Content -Path $bundlePath -Value $bundleJson -Encoding utf8
    }

    [PSCustomObject]@{
        BundlePath = $bundlePath
        Bundle     = $bundlePayload
    }
}

function Get-ReplacementAgent {
    [CmdletBinding()]
    param(
        [string] $LockedOutAgent,
        [string[]] $SuggestedAgents
    )

    foreach ($agent in @($SuggestedAgents)) {
        if (-not [string]::IsNullOrWhiteSpace($agent) -and $agent -ne $LockedOutAgent) {
            return $agent
        }
    }

    $fallbackAgents = @('forge', 'atlas', 'iris', 'sage', 'sentinel', 'lead')
    foreach ($agent in $fallbackAgents) {
        if ($agent -ne $LockedOutAgent) {
            return $agent
        }
    }

    'unassigned'
}

function ConvertTo-TriageResponse {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Response
    )

    if ($null -eq $Response) {
        return $null
    }

    if ($Response -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Response)) {
            return $null
        }
        $Response = $Response | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $Response) {
            return $null
        }
    }

    $verdict = if ($Response.reviewerVerdict) { [string]$Response.reviewerVerdict } else { 'COMMENTED' }
    $findings = @($Response.consensusFindings | Where-Object { $_ })
    $disputed = @($Response.disputedFindings | Where-Object { $_ })
    $actions = @($Response.actionPlan | Where-Object { $_ })
    $recommendedOwner = [string]$Response.recommendedRevisionOwner

    [PSCustomObject]@{
        ReviewerVerdict          = $verdict
        ConsensusFindings        = @($findings)
        DisputedFindings         = @($disputed)
        ActionPlan               = @($actions)
        RecommendedRevisionOwner = $recommendedOwner
    }
}

function Merge-TriageResponses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $FeedbackPayload,

        [object[]] $Responses = @(),

        [string] $LockedOutAgent
    )

    $normalized = @(
        $Responses |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ConvertTo-TriageResponse -Response $_ } |
            Where-Object { $null -ne $_ }
    )
    if ($normalized.Count -eq 0) {
        $autoVerdict = if ($FeedbackPayload.Reviews | Where-Object { $_.State -eq 'CHANGES_REQUESTED' }) {
            'CHANGES_REQUESTED'
        } elseif ($FeedbackPayload.Reviews | Where-Object { $_.State -eq 'APPROVED' }) {
            'APPROVED'
        } else {
            'COMMENTED'
        }

        $autoFindings = foreach ($comment in @($FeedbackPayload.LineComments)) {
            [PSCustomObject]@{
                title    = "Line comment: $($comment.Path):$($comment.Line)"
                detail   = $comment.Body
                path     = $comment.Path
                line     = $comment.Line
                severity = 'Medium'
            }
        }

        $recommendedOwner = Get-ReplacementAgent -LockedOutAgent $LockedOutAgent -SuggestedAgents @()
        return [PSCustomObject]@{
            ReviewerVerdict          = $autoVerdict
            ConsensusFindings        = @($autoFindings)
            DisputedFindings         = @()
            ActionPlan               = @(
                'Address all CHANGES_REQUESTED and unresolved line comments.',
                'Reply on each review thread with fix reference or rationale.',
                'Re-run 3-model rubber-duck gate before re-requesting review.',
                'Lockout enforcement: rejected PR author must not execute revisions in this cycle.'
            )
            LockedOutAgent           = if ($LockedOutAgent) { $LockedOutAgent } else { 'unknown' }
            RecommendedRevisionOwner = $recommendedOwner
        }
    }

    $verdictCounts = @{}
    foreach ($response in $normalized) {
        $key = [string]$response.ReviewerVerdict
        if (-not $verdictCounts.ContainsKey($key)) {
            $verdictCounts[$key] = 0
        }
        $verdictCounts[$key]++
    }

    $consensusVerdict = 'APPROVED'
    if ($verdictCounts.ContainsKey('CHANGES_REQUESTED')) {
        $consensusVerdict = 'CHANGES_REQUESTED'
    } elseif ($verdictCounts.ContainsKey('COMMENTED')) {
        $consensusVerdict = 'COMMENTED'
    } elseif ($verdictCounts.ContainsKey('APPROVED')) {
        $consensusVerdict = 'APPROVED'
    }

    $findingMap = @{}
    $allFindings = [System.Collections.Generic.List[object]]::new()
    foreach ($response in $normalized) {
        foreach ($finding in @($response.ConsensusFindings | Where-Object { $_ })) {
            $path = [string]$finding.path
            $line = if ($null -ne $finding.line) { [string]$finding.line } else { '' }
            $title = [string]$finding.title
            $detail = [string]$finding.detail
            $key = "$path|$line|$title|$detail"
            if (-not $findingMap.ContainsKey($key)) {
                $findingMap[$key] = 0
                $allFindings.Add([PSCustomObject]@{
                        title    = $title
                        detail   = $detail
                        path     = $path
                        line     = $finding.line
                        severity = if ($finding.severity) { [string]$finding.severity } else { 'Medium' }
                    })
            }
            $findingMap[$key]++
        }
    }

    $consensusFindings = [System.Collections.Generic.List[object]]::new()
    $disputedFindings = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in $allFindings) {
        $lineKey = if ($null -ne $finding.line) { [string]$finding.line } else { '' }
        $key = "$($finding.path)|$lineKey|$($finding.title)|$($finding.detail)"
        if ($findingMap[$key] -ge 2) {
            $consensusFindings.Add($finding)
        } else {
            $disputedFindings.Add($finding)
        }
    }

    foreach ($response in $normalized) {
        foreach ($finding in @($response.DisputedFindings | Where-Object { $_ })) {
            $disputedFindings.Add([PSCustomObject]@{
                    title    = [string]$finding.title
                    detail   = [string]$finding.detail
                    path     = [string]$finding.path
                    line     = $finding.line
                    severity = if ($finding.severity) { [string]$finding.severity } else { 'Medium' }
                })
        }
    }

    $actions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($response in $normalized) {
        foreach ($action in @($response.ActionPlan | Where-Object { $_ })) {
            $safeAction = Remove-Credentials ([string]$action)
            if (-not [string]::IsNullOrWhiteSpace($safeAction)) {
                [void]$actions.Add($safeAction)
            }
        }
    }
    [void]$actions.Add('Lockout enforcement: rejected PR author must not execute revisions in this cycle.')

    $suggested = @($normalized | ForEach-Object { $_.RecommendedRevisionOwner } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $recommendedOwner = Get-ReplacementAgent -LockedOutAgent $LockedOutAgent -SuggestedAgents $suggested

    [PSCustomObject]@{
        ReviewerVerdict          = $consensusVerdict
        ConsensusFindings        = @($consensusFindings)
        DisputedFindings         = @($disputedFindings)
        ActionPlan               = @($actions)
        LockedOutAgent           = if ($LockedOutAgent) { $LockedOutAgent } else { 'unknown' }
        RecommendedRevisionOwner = $recommendedOwner
    }
}

function Save-ReviewPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Consensus,

        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [string] $Agent = 'sentinel',

        [switch] $DryRun
    )

    $filePath = Join-Path $OutputPath "$Agent-pr-$PRNumber-review.md"
    $consensusLines = @($Consensus.ConsensusFindings | ForEach-Object {
            "- [$($_.severity)] $($_.title) (``$($_.path):$($_.line)``)`n  - $($_.detail)"
        })
    if ($consensusLines.Count -eq 0) {
        $consensusLines = @('- None')
    }

    $disputedLines = @($Consensus.DisputedFindings | ForEach-Object {
            "- [$($_.severity)] $($_.title) (``$($_.path):$($_.line)``)`n  - $($_.detail)"
        })
    if ($disputedLines.Count -eq 0) {
        $disputedLines = @('- None')
    }

    $actionLines = @($Consensus.ActionPlan | ForEach-Object { "- $_" })
    if ($actionLines.Count -eq 0) {
        $actionLines = @('- No action plan provided')
    }

    $content = @"
# PR #$PRNumber Review Gate Consensus

## Reviewer Verdict
$($Consensus.ReviewerVerdict)

## Consensus Findings
$($consensusLines -join "`n")

## Disputed Findings
$($disputedLines -join "`n")

## Action Plan
$($actionLines -join "`n")

## Reviewer Lockout Notice
- Locked-out agent: $($Consensus.LockedOutAgent)
- Replacement revision owner: $($Consensus.RecommendedRevisionOwner)
- Rule: rejected PR author must not self-revise in the same gate cycle.
"@

    $safeContent = Remove-Credentials $content
    if (-not $DryRun) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        Set-Content -Path $filePath -Value $safeContent -Encoding utf8
    }

    [PSCustomObject]@{
        Path    = $filePath
        Content = $safeContent
    }
}

function Post-PRSummaryComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $Repo,

        [Parameter(Mandatory)]
        [psobject] $Consensus,

        [Parameter(Mandatory)]
        [string] $PlanPath,

        [switch] $DryRun
    )

    $marker = '<!-- squad-pr-review-gate -->'
    $actions = @($Consensus.ActionPlan | ForEach-Object { "- $_" })
    $body = @"
$marker
### PR Review Gate Summary

- Verdict: **$($Consensus.ReviewerVerdict)**
- Locked-out agent: **$($Consensus.LockedOutAgent)**
- Replacement revision owner: **$($Consensus.RecommendedRevisionOwner)**
- Consensus plan: `$PlanPath`

What will change:
$($actions -join "`n")

_Updated in place on each review event — see PR timeline for full history._
"@
    $safeBody = Remove-Credentials $body

    if ($DryRun) {
        Write-Host "[DryRun] Upsert squad-pr-review-gate comment on PR $PRNumber (repo $Repo)"
        return
    }

    # Look for existing gate comment to update in place (prevents email noise on re-runs)
    $existingId = $null
    try {
        $commentsJson = & gh api "repos/$Repo/issues/$PRNumber/comments" --paginate 2> $null
        if ($LASTEXITCODE -eq 0 -and $commentsJson) {
            $existing = $commentsJson | ConvertFrom-Json
            $match = @($existing | Where-Object { $_.body -and $_.body.Contains($marker) } | Select-Object -First 1)
            if ($match.Count -gt 0) {
                $existingId = [string]$match[0].id
            }
        }
    } catch {
        Write-Verbose "Could not list existing comments, will post new: $_"
    }

    $bodyFilePath = New-RepoTempFile -Prefix 'pr-review-comment'
    $stderrPath = New-RepoTempFile -Prefix 'pr-review-comment-err'
    $maxRetries = 3
    try {
        Set-Content -Path $bodyFilePath -Value $safeBody -Encoding utf8
        for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
            # See Invoke-GhApiPaged: reset LASTEXITCODE so function-mocked `gh`
            # in Pester does not inherit a stale non-zero from a prior native call.
            $global:LASTEXITCODE = 0
            if ($existingId) {
                & gh api --method PATCH "repos/$Repo/issues/comments/$existingId" -F "body=@$bodyFilePath" 1> $null 2> $stderrPath
            } else {
                & gh pr comment $PRNumber --repo $Repo --body-file $bodyFilePath 1> $null 2> $stderrPath
            }
            $exitCode = 0
            $exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            if ($exitCodeVar) {
                $exitCode = [int]$exitCodeVar.Value
            }

            if ($exitCode -eq 0) {
                break
            }

            $errorText = ''
            if (Test-Path $stderrPath) {
                $errorText = Remove-Credentials (Get-Content -Path $stderrPath -Raw)
            }
            $retryable = $errorText -match '(?i)(429|rate limit|503|timeout|temporar)'
            if ($retryable -and $attempt -lt ($maxRetries - 1)) {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                continue
            }

            throw "gh pr comment failed: $errorText"
        }
    } finally {
        Remove-Item -Path $bodyFilePath -ErrorAction SilentlyContinue
        Remove-Item -Path $stderrPath -ErrorAction SilentlyContinue
    }
}

function Get-ModelResponses {
    [CmdletBinding()]
    param(
        [string] $ModelResponsesPath
    )

    $rawText = $null
    if ($ModelResponsesPath) {
        if (-not (Test-Path $ModelResponsesPath)) {
            throw "ModelResponsesPath not found: $ModelResponsesPath"
        }

        $rawText = Get-Content -Path $ModelResponsesPath -Raw
    } elseif (-not [string]::IsNullOrWhiteSpace($env:PR_REVIEW_GATE_RESPONSES_JSON)) {
        $rawText = $env:PR_REVIEW_GATE_RESPONSES_JSON
    }

    if ([string]::IsNullOrWhiteSpace($rawText)) {
        return @()
    }

    $parsed = $rawText | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $parsed) {
        return @()
    }

    @($parsed | Where-Object { $null -ne $_ })
}

function Invoke-PRReviewGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,
        [string] $Repo = 'martinopedal/azure-analyzer',
        [string] $OutputPath = '.squad/decisions/inbox/',
        [string] $ModelResponsesPath,
        [string] $Agent = 'sentinel',
        [string] $PRAuthorAgent = $env:PR_AUTHOR_AGENT,
        [switch] $DryRun
    )

    try {
        $feedback = Get-PRReviewFeedback -PRNumber $PRNumber -Repo $Repo
        $promptBundle = Invoke-MultiModelTriage -FeedbackPayload $feedback -OutputPath $OutputPath -DryRun:$DryRun
        $responses = Get-ModelResponses -ModelResponsesPath $ModelResponsesPath
        $consensus = Merge-TriageResponses -FeedbackPayload $feedback -Responses $responses -LockedOutAgent $PRAuthorAgent
        if ([string]::IsNullOrWhiteSpace($PRAuthorAgent)) {
            throw 'PRAuthorAgent is required for mechanical lockout enforcement.'
        }

        if ($consensus.RecommendedRevisionOwner -eq $PRAuthorAgent) {
            throw "Lockout enforcement failed: replacement owner matches PR author '$PRAuthorAgent'."
        }

        $plan = Save-ReviewPlan -Consensus $consensus -PRNumber $PRNumber -OutputPath $OutputPath -Agent $Agent -DryRun:$DryRun
        Post-PRSummaryComment -PRNumber $PRNumber -Repo $Repo -Consensus $consensus -PlanPath $plan.Path -DryRun:$DryRun

        [PSCustomObject]@{
            Status       = 'Success'
            Feedback     = $feedback
            PromptBundle = $promptBundle
            Consensus    = $consensus
            PlanPath     = $plan.Path
            DryRun       = [bool]$DryRun
        }
    } catch {
        $safeError = Remove-Credentials ([string]$_.Exception.Message)
        $location = ''
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $location = Remove-Credentials ([string]$_.InvocationInfo.PositionMessage)
        }
        Write-Warning "Invoke-PRReviewGate failed: $safeError"
        if ($location) {
            Write-Warning $location
        }
        [PSCustomObject]@{
            Status   = 'Failed'
            Message  = $safeError
            Location = $location
            DryRun   = [bool]$DryRun
            PlanPath = $null
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($PRNumber -lt 1) {
        throw 'PRNumber is required when running Invoke-PRReviewGate.ps1 directly.'
    }

    $result = Invoke-PRReviewGate `
        -PRNumber $PRNumber `
        -Repo $Repo `
        -OutputPath $OutputPath `
        -ModelResponsesPath $ModelResponsesPath `
        -Agent $Agent `
        -PRAuthorAgent $PRAuthorAgent `
        -DryRun:$DryRun

    if ($result.Status -ne 'Success') {
        exit 1
    }
}
