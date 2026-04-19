#Requires -Version 7.4
<#
.SYNOPSIS
    Universal advisory review gate for squad-authored PRs (#109).

.DESCRIPTION
    Fires on every squad PR open/ready/synchronize event. Builds a 3-model
    triage prompt bundle in `.squad/decisions/inbox/` (reusing the patterns
    from `Invoke-PRReviewGate.ps1`), then posts or updates a single advisory
    comment on the PR under the `<!-- squad-advisory -->` marker.

    This is NON-BLOCKING. The gate posts findings tagged per the #108 severity
    taxonomy. Untagged findings are auto-tagged `[correctness]` (fail-safe).
    Merge is never blocked by this gate, the human / Copilot reviewer has the
    final say.

    Disable repo-wide via the `SQUAD_ADVISORY_GATE=0` repo variable.

.PARAMETER PRNumber
    The PR number to advise on.

.PARAMETER Repo
    The owner/name slug, e.g. `martinopedal/azure-analyzer`.

.PARAMETER PRAuthor
    Author login from the triggering event. Used by the squad-author filter.

.PARAMETER OutputPath
    Where to write the triage prompt bundle. Defaults to `.squad/decisions/inbox/`.

.PARAMETER Enabled
    Master switch. When `$false`, exits early with a no-op (used by the
    workflow when `SQUAD_ADVISORY_GATE=0`).

.PARAMETER DryRun
    Skip filesystem writes and `gh` calls. Returns the would-be payload.
#>
[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)]
    [int] $PRNumber = 0,

    [ValidateNotNullOrEmpty()]
    [string] $Repo = 'martinopedal/azure-analyzer',

    [string] $PRAuthor = $env:PR_AUTHOR,

    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = '.squad/decisions/inbox/',

    [string] $HeadSha = $env:PR_HEAD_SHA,

    [string] $CopilotTriagePlanPath = '',

    [bool] $Enabled = $true,

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Sanitize.ps1')
. (Join-Path $PSScriptRoot 'RubberDuckChain.ps1')

# Marker used to find and update the single advisory comment in place.
$script:AdvisoryMarker = '<!-- squad-advisory -->'

function Import-CopilotTriagePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $PlanPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($PlanPath)) {
        return [pscustomobject]@{
            PlanHash = 'no-copilot-findings'
            Items    = @()
            Summary  = [pscustomobject]@{
                TotalFindings              = 0
                CategoryCounts             = [pscustomobject]@{ blocker = 0; correctness = 0; security = 0; style = 0; nit = 0 }
                CopilotThreadStates        = @()
                UnaddressedCopilotThreads  = @()
                AllCopilotThreadsAddressed = $true
            }
        }
    }

    if (-not (Test-Path -LiteralPath $PlanPath)) {
        throw "Copilot triage plan file not found: $PlanPath"
    }

    $raw = Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Copilot triage plan file is empty: $PlanPath"
    }

    $plan = $raw | ConvertFrom-Json -Depth 30
    if (-not $plan.PSObject.Properties['PlanHash'] -or [string]::IsNullOrWhiteSpace([string]$plan.PlanHash)) {
        $plan | Add-Member -NotePropertyName PlanHash -NotePropertyValue 'no-copilot-findings' -Force
    }
    if (-not $plan.PSObject.Properties['Items']) {
        $plan | Add-Member -NotePropertyName Items -NotePropertyValue @() -Force
    }
    if (-not $plan.PSObject.Properties['Summary']) {
        $plan | Add-Member -NotePropertyName Summary -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $plan.Summary.PSObject.Properties['AllCopilotThreadsAddressed']) {
        $plan.Summary | Add-Member -NotePropertyName AllCopilotThreadsAddressed -NotePropertyValue $true -Force
    }
    if (-not $plan.Summary.PSObject.Properties['UnaddressedCopilotThreads']) {
        $plan.Summary | Add-Member -NotePropertyName UnaddressedCopilotThreads -NotePropertyValue @() -Force
    }
    $plan
}

function Format-CopilotFindingsSection {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $CopilotTriagePlan = $null
    )

    if ($null -eq $CopilotTriagePlan -or -not $CopilotTriagePlan.PSObject.Properties['Items']) {
        return @"
## Copilot review findings
- none
"@
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('## Copilot review findings')
    [void]$lines.Add("Plan hash: $([string]$CopilotTriagePlan.PlanHash)")

    $items = @($CopilotTriagePlan.Items)
    if ($items.Count -eq 0) {
        [void]$lines.Add('- none')
    } else {
        foreach ($group in $items) {
            $category = [string]$group.Category
            [void]$lines.Add("- [$category] count=$([int]$group.Count)")
            foreach ($f in @($group.Findings)) {
                $path = [string]$f.Path
                $line = if ($null -eq $f.Line) { '?' } else { [string]$f.Line }
                $body = [string]$f.Body
                if ($body.Length -gt 260) { $body = $body.Substring(0, 260) + '...' }
                $body = $body -replace '\r?\n', ' '
                [void]$lines.Add("  - ${path}:$line :: $body")
            }
        }
    }

    if ($CopilotTriagePlan.PSObject.Properties['Summary'] -and $CopilotTriagePlan.Summary) {
        $summary = $CopilotTriagePlan.Summary
        $allAddressed = [bool]$summary.AllCopilotThreadsAddressed
        [void]$lines.Add('')
        [void]$lines.Add("AllCopilotThreadsAddressed: $allAddressed")
        $unaddressed = @($summary.UnaddressedCopilotThreads)
        if ($unaddressed.Count -gt 0) {
            [void]$lines.Add('Unaddressed threads:')
            foreach ($t in $unaddressed) {
                [void]$lines.Add("- $([string]$t.ThreadId) (category=$([string]$t.Category))")
            }
        }
    }

    $lines -join "`n"
}

<#
Squad-author heuristic
----------------------
A PR is "squad-authored" when ANY of these hold:
  1. The login matches the squad-agent bot pattern
     `*-swe-agent[bot]` (for example `copilot-swe-agent[bot]`).
  2. The login matches one of the squad agent identities
     (forge, atlas, iris, sage, sentinel, lead, scribe).
  3. The login is listed in the comma-separated `SQUAD_AGENT_LOGINS`
     env var (escape hatch for repo-specific identities).

Human PRs are skipped, the advisory gate is for AI-authored work only.
#>
function Test-SquadAuthor {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Login
    )

    if ([string]::IsNullOrWhiteSpace($Login)) {
        return $false
    }

    $normalized = $Login.Trim().ToLowerInvariant()

    $excludedAutomationBots = @(
        'dependabot[bot]',
        'renovate[bot]',
        'github-actions[bot]'
    )
    if ($excludedAutomationBots -contains $normalized) {
        return $false
    }

    if ($normalized -match '^[a-z0-9-]+-swe-agent\[bot\]$') {
        return $true
    }

    $builtIn = @(
        'forge',
        'atlas',
        'iris',
        'sage',
        'sentinel',
        'lead',
        'scribe'
    )
    if ($builtIn -contains $normalized) {
        return $true
    }

    $extra = $env:SQUAD_AGENT_LOGINS
    if (-not [string]::IsNullOrWhiteSpace($extra)) {
        foreach ($candidate in $extra.Split(',')) {
            $trimmed = $candidate.Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and $trimmed -eq $normalized) {
                return $true
            }
        }
    }

    return $false
}

function Test-SkipAdvisoryLabel {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $Repo
    )

    $labels = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($env:PR_LABELS)) {
        foreach ($name in ($env:PR_LABELS -split '[,\r\n]')) {
            $trimmed = [string]$name
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                [void]$labels.Add($trimmed.Trim())
            }
        }
    } else {
        $rawLabels = & gh pr view $PRNumber --repo $Repo --json labels -q '.labels[].name' 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$rawLabels)) {
            foreach ($name in ([string]$rawLabels -split '[\r\n]')) {
                $trimmed = [string]$name
                if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                    [void]$labels.Add($trimmed.Trim())
                }
            }
        }
    }

    foreach ($label in $labels) {
        if ($label.ToLowerInvariant() -eq 'skip-advisory') {
            return $true
        }
    }

    return $false
}

<#
Severity tag enforcement (#108 contract).

Untagged findings -> `[correctness]` (fail-safe).
Tagged findings are returned as-is, with the tag normalized to lowercase
so downstream regex matches stay simple.
#>
function Add-SeverityTag {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Finding
    )

    if ([string]::IsNullOrWhiteSpace($Finding)) {
        return '[correctness] (empty finding)'
    }

    $trimmed = $Finding.TrimStart()
    $tagPattern = '^\[(blocker|correctness|security|style|nit)\]'

    if ($trimmed -match $tagPattern) {
        # Normalize tag casing while preserving the rest verbatim.
        $tag = $Matches[1].ToLowerInvariant()
        $rest = $trimmed.Substring($Matches[0].Length).TrimStart()
        return "[$tag] $rest"
    }

    return "[correctness] $trimmed"
}

<#
Build the markdown body for the advisory comment. Idempotent so the workflow
can update the same comment in place on each synchronize.
#>
function Format-AdvisoryComment {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,

        [string[]] $Findings = @(),

        [ValidateSet('clean', 'concerns', 'blockers')]
        [string] $Verdict = 'clean',

        [string] $HeadSha = '',

        [int] $Approves = 0,

        [int] $TotalModels = 0
    )

    $tagged = @()
    foreach ($f in @($Findings)) {
        $tagged += Add-SeverityTag -Finding $f
    }

    $hasVeto = $tagged | Where-Object { $_ -match '^\[(blocker|correctness|security)\]' }
    if ($hasVeto) {
        $Verdict = 'blockers'
    } elseif ($tagged.Count -gt 0 -and $Verdict -eq 'clean') {
        $Verdict = 'concerns'
    }

    $emoji = switch ($Verdict) {
        'clean'    { '[OK]' }
        'concerns' { '[!]' }
        'blockers' { '[X]' }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add($script:AdvisoryMarker)
    if (-not [string]::IsNullOrWhiteSpace($HeadSha)) {
        [void]$lines.Add("<!-- head-sha: $HeadSha -->")
    }
    [void]$lines.Add('## Advisory review (3-model consensus)')
    [void]$lines.Add('')
    [void]$lines.Add("**Verdict:** $emoji $Verdict")
    if ($TotalModels -gt 0) {
        [void]$lines.Add("**Models APPROVE:** $Approves / $TotalModels")
    }
    if (-not [string]::IsNullOrWhiteSpace($HeadSha)) {
        $shortSha = if ($HeadSha.Length -ge 7) { $HeadSha.Substring(0, 7) } else { $HeadSha }
        [void]$lines.Add("**Head SHA:** ``$shortSha``")
    }
    [void]$lines.Add('')
    [void]$lines.Add('### Findings')
    if ($tagged.Count -eq 0) {
        [void]$lines.Add('- None. Triage bundle queued for the 3-model gate.')
    } else {
        foreach ($t in $tagged) {
            [void]$lines.Add("- $t")
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('> Advisory only. Does not block merge. Human / Copilot reviewer has final say.')
    [void]$lines.Add("> Severity tags follow the #108 taxonomy. Untagged findings are auto-tagged ``[correctness]`` (fail-safe).")
    [void]$lines.Add('')
    [void]$lines.Add("_PR #$PRNumber, generated by ``pr-advisory-gate.yml`` (#109)._")

    return ($lines -join "`n")
}

<#
Locate an existing advisory comment by marker. Returns the comment id or
$null when none exists. Pure wrapper around `gh api` paginated comments
fetch, kept thin so the integration path stays simple.
#>
function Get-AdvisoryCommentId {
    [CmdletBinding()]
    [OutputType([nullable[long]])]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $Repo
    )

    $endpoint = "repos/$Repo/issues/$PRNumber/comments"
    $raw = & gh api $endpoint --paginate --slurp 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        return $null
    }

    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    $pages = @($parsed)
    $comments = [System.Collections.Generic.List[object]]::new()
    foreach ($page in $pages) {
        if ($null -eq $page) {
            continue
        }
        if ($page -is [System.Collections.IEnumerable] -and -not ($page -is [string])) {
            foreach ($comment in @($page)) {
                [void]$comments.Add($comment)
            }
            continue
        }
        [void]$comments.Add($page)
    }

    $latestMatchId = $null
    foreach ($c in $comments) {
        $body = [string]$c.body
        if ($body -and $body.Contains($script:AdvisoryMarker)) {
            $id = [long]$c.id
            if ($null -eq $latestMatchId -or $id -gt $latestMatchId) {
                $latestMatchId = $id
            }
        }
    }
    return $latestMatchId
}

<#
Post or update the advisory comment idempotently.
#>
function Publish-AdvisoryComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $Repo,

        [Parameter(Mandatory)]
        [string] $Body,

        [switch] $DryRun
    )

    $safeBody = Remove-Credentials $Body

    if ($DryRun) {
        Write-Verbose "DryRun: would publish advisory comment on PR #$PRNumber ($($safeBody.Length) chars)."
        return $safeBody
    }

    $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "advisory-$PRNumber-$([guid]::NewGuid().ToString('N')).md"
    Set-Content -Path $bodyFile -Value $safeBody -Encoding utf8

    try {
        $existingId = Get-AdvisoryCommentId -PRNumber $PRNumber -Repo $Repo
        if ($existingId) {
            $endpoint = "repos/$Repo/issues/comments/$existingId"
            & gh api -X PATCH $endpoint -F "body=@$bodyFile" 1>$null
        } else {
            $endpoint = "repos/$Repo/issues/$PRNumber/comments"
            & gh api -X POST $endpoint -F "body=@$bodyFile" 1>$null
        }

        if ($LASTEXITCODE -ne 0) {
            throw "gh api failed with exit code $LASTEXITCODE while publishing advisory comment."
        }
    } finally {
        Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue
    }

    return $safeBody
}

# --- Frontier rubber-duck roster + per-model invocation -------------------
# Strict allow-list. See `.copilot/copilot-instructions.md` -> "Frontier
# Model Roster". DO NOT add opus-4.6, opus-4.5, sonnet-anything,
# haiku-anything, mini-anything, or gpt-4.1 here.
function Get-FrontierModelRoster {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    @(
        'claude-opus-4.7',
        'gpt-5.3-codex',
        'goldeneye'
    )
}

<#
Per-model rubber-duck invocation.

TODO(#157 follow-up): swap the deterministic stub for a real provider
call (GitHub Models REST or `gh copilot suggest`). Today we ship the
gate scaffolding -- prompt persistence, roster, verdict aggregation,
commit-status posting -- and stub the model verdict to APPROVE / no
findings so the workflow is exercised end-to-end on every push. The
prompt bundle written to `.squad/decisions/inbox/` is real, so the
follow-up only needs to flip the inner call.
#>
function Invoke-RubberDuckModel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ModelName,

        [Parameter(Mandatory)]
        [string] $Prompt,

        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $HeadSha,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [string] $PlanHash = 'no-copilot-findings',

        [switch] $DryRun
    )

    $safeModel = $ModelName -replace '[^A-Za-z0-9._-]', '-'
    $safeSha = if ([string]::IsNullOrWhiteSpace($HeadSha)) { 'no-sha' } else { ($HeadSha -replace '[^A-Za-z0-9]', '').Substring(0, [math]::Min(12, $HeadSha.Length)) }
    $safePlan = if ([string]::IsNullOrWhiteSpace($PlanHash)) { 'no-plan' } else { ($PlanHash -replace '[^A-Za-z0-9]', '').Substring(0, [math]::Min(16, $PlanHash.Length)) }
    $promptFile = Join-Path $OutputPath "$PRNumber-$safeSha-$safePlan-$safeModel.md"
    $responseFile = Join-Path $OutputPath "$PRNumber-$safeSha-$safePlan-$safeModel.response.json"

    if (-not $DryRun -and (Test-Path -LiteralPath $responseFile)) {
        $cachedRaw = Get-Content -LiteralPath $responseFile -Raw -Encoding utf8
        if (-not [string]::IsNullOrWhiteSpace($cachedRaw)) {
            $cached = $cachedRaw | ConvertFrom-Json -Depth 20
            return [pscustomobject]@{
                Model    = [string]$cached.Model
                Verdict  = [string]$cached.Verdict
                Findings = @($cached.Findings)
                Stub     = [bool]$cached.Stub
                Cached   = $true
            }
        }
    }

    if (-not $DryRun) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        $safePrompt = Remove-Credentials $Prompt
        Set-Content -Path $promptFile -Value $safePrompt -Encoding utf8
    }

    $response = [pscustomobject]@{
        Model    = $ModelName
        Verdict  = 'APPROVE'
        Findings = @()
        Stub     = $true
        Cached   = $false
    }
    if (-not $DryRun) {
        $safeResponse = Remove-Credentials ($response | ConvertTo-Json -Depth 10)
        Set-Content -Path $responseFile -Value $safeResponse -Encoding utf8
    }
    return $response
}

<#
Build the diff bundle, fan out across the frontier roster via the
retry+swap chain, return raw per-model responses plus chain outcome
metadata. Each run is keyed to the head SHA so re-runs on synchronize
start from scratch.

Returned object shape:
    @{
        Outcome   = 'Success' | 'ChainExhausted' | 'SwapLimitExceeded'
        Responses = pscustomobject[]   # per-model { Verdict, Findings }
        Swaps     = int
    }
#>
function Invoke-AdvisoryRubberDuck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [int] $PRNumber,

        [Parameter(Mandatory)]
        [string] $Repo,

        [Parameter(Mandatory)]
        [string] $HeadSha,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [AllowNull()]
        [object] $CopilotTriagePlan = $null,

        [scriptblock] $CallInvoker,

        [scriptblock] $Sleep = { param($s) Start-Sleep -Seconds $s },

        [switch] $DryRun
    )

    $diff = ''
    if (-not $DryRun) {
        try {
            $rawDiff = & gh pr diff $PRNumber --repo $Repo 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$rawDiff)) {
                $diff = [string]$rawDiff
            }
        } catch {
            $diff = ''
        }
    }
    if ([string]::IsNullOrWhiteSpace($diff)) {
        $diff = '(diff unavailable)'
    }
    $diff = Remove-Credentials $diff
    if ($diff.Length -gt 60000) {
        $diff = $diff.Substring(0, 60000) + "`n... (truncated)"
    }

    $context = @{
        Diff       = $diff
        PRNumber   = $PRNumber
        HeadSha    = $HeadSha
        OutputPath = $OutputPath
        DryRun     = [bool]$DryRun
        PlanHash   = if ($CopilotTriagePlan) { [string]$CopilotTriagePlan.PlanHash } else { 'no-copilot-findings' }
        CopilotSection = (Format-CopilotFindingsSection -CopilotTriagePlan $CopilotTriagePlan)
    }

    if ($null -eq $CallInvoker) {
        $CallInvoker = {
            param($model, $ctx)
            $prompt = @"
You are model '$model' in the rubber-duck PR review gate for PR #$($ctx.PRNumber) @ $($ctx.HeadSha).

Tag every finding with one of: [blocker] [correctness] [security] [style] [nit].
Untagged findings are auto-tagged [correctness] (fail-safe).

Return strict JSON:
{
  "verdict": "APPROVE" | "REQUEST_CHANGES",
  "findings": ["[tag] short message", ...]
}

DIFF:
$($ctx.Diff)

$($ctx.CopilotSection)
"@
            return Invoke-RubberDuckModel `
                -ModelName $model `
                -Prompt $prompt `
                -PRNumber $ctx.PRNumber `
                -HeadSha $ctx.HeadSha `
                -OutputPath $ctx.OutputPath `
                -PlanHash $ctx.PlanHash `
                -DryRun:$ctx.DryRun
        }
    }

    $chainResult = Invoke-RubberDuckTrio `
        -PRNumber $PRNumber `
        -HeadSha $HeadSha `
        -CallContext $context `
        -CallInvoker $CallInvoker `
        -OutputPath $OutputPath `
        -Sleep $Sleep `
        -DryRun:$DryRun

    $responses = @()
    foreach ($v in @($chainResult.Verdicts)) {
        if ($null -eq $v -or $null -eq $v.Response) { continue }
        $responses += $v.Response
    }

    [pscustomobject]@{
        Outcome   = $chainResult.Outcome
        Responses = @($responses)
        Swaps     = $chainResult.Swaps
    }
}

<#
Apply the Gate-pass criteria from `.copilot/copilot-instructions.md` ->
"Review Severity Taxonomy" -> "Gate-pass criteria":

  Pass when ALL hold:
    1. Zero [blocker] / [correctness] findings across all responses.
    2. At least 2 of N models returned APPROVE.

The aggregate verdict is `blockers` when any veto-class finding lands,
`concerns` when only [style] / [nit] findings exist, otherwise `clean`.
#>
function Resolve-RubberDuckVerdict {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object[]] $Responses = @(),
        [bool] $AllCopilotThreadsAddressed = $true
    )

    $arr = @($Responses | Where-Object { $_ })
    $approves = @($arr | Where-Object { [string]$_.Verdict -eq 'APPROVE' }).Count
    $totalModels = $arr.Count

    $tagged = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $arr) {
        foreach ($f in @($r.Findings)) {
            $line = Add-SeverityTag -Finding ([string]$f)
            [void]$tagged.Add($line)
        }
    }

    $hasVeto = @($tagged | Where-Object { $_ -match '^\[(blocker|correctness|security)\]' }).Count -gt 0

    $verdict = 'clean'
    if ($hasVeto) {
        $verdict = 'blockers'
    } elseif ($tagged.Count -gt 0) {
        $verdict = 'concerns'
    }

    $passed = ($approves -ge 2) -and (-not $hasVeto) -and $AllCopilotThreadsAddressed

    [pscustomobject]@{
        Passed                      = $passed
        Approves                    = $approves
        TotalModels                 = $totalModels
        Findings                    = @($tagged)
        Verdict                     = $verdict
        AllCopilotThreadsAddressed  = $AllCopilotThreadsAddressed
    }
}

# --- Main entrypoint guard ---
# Tests dot-source this file to exercise the pure functions. Skip the main
# block in that case by checking whether we were invoked as a script.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.MyCommand.Path -eq $PSCommandPath) {
    # Emit a default gate-state on every early-return path so the workflow's
    # `Post rubberduck-gate commit status` step always has a verdict to post
    # against the PR head SHA. Branch protection requires the status context
    # to exist on every PR (#173). Skipped runs are non-failures -> success.
    function script:Write-SkipGateOutput {
        param([string] $Reason)
        Write-Host "rubberduck-gate state: success (skipped: $Reason)"
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
            Add-Content -Path $env:GITHUB_OUTPUT -Value 'gate-state=success'
            Add-Content -Path $env:GITHUB_OUTPUT -Value "head-sha=$HeadSha"
            Add-Content -Path $env:GITHUB_OUTPUT -Value "skip-reason=$Reason"
        }
    }

    if (-not $Enabled) {
        Write-Host 'Advisory gate disabled (SQUAD_ADVISORY_GATE=0). Skipping.'
        Write-SkipGateOutput -Reason 'disabled'
        return
    }

    if ($PRNumber -le 0) {
        throw 'PRNumber must be a positive integer.'
    }

    if (-not (Test-SquadAuthor -Login $PRAuthor)) {
        Write-Host "PR author '$PRAuthor' is not a squad agent / bot. Skipping advisory gate."
        Write-SkipGateOutput -Reason 'non-squad-author'
        return
    }

    if (Test-SkipAdvisoryLabel -PRNumber $PRNumber -Repo $Repo) {
        Write-SkipGateOutput -Reason 'skip-advisory-label'
        return
    }

    Write-Host "Squad-authored PR #$PRNumber detected (author: $PRAuthor). Building advisory triage bundle..."

    if (-not $DryRun) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($HeadSha)) {
        try {
            $resolved = & gh pr view $PRNumber --repo $Repo --json headRefOid -q '.headRefOid' 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                $HeadSha = ([string]$resolved).Trim()
            }
        } catch {
            $HeadSha = ''
        }
    }

    $copilotTriagePlan = Import-CopilotTriagePlan -PlanPath $CopilotTriagePlanPath

    $advisory = Invoke-AdvisoryRubberDuck `
        -PRNumber $PRNumber `
        -Repo $Repo `
        -HeadSha $HeadSha `
        -OutputPath $OutputPath `
        -CopilotTriagePlan $copilotTriagePlan `
        -DryRun:$DryRun

    if ($advisory.Outcome -in 'ChainExhausted', 'SwapLimitExceeded') {
        $stickyBody = Format-ChainExhaustedComment `
            -PRNumber $PRNumber `
            -HeadSha $HeadSha `
            -Swaps $advisory.Swaps
        Publish-AdvisoryComment -PRNumber $PRNumber -Repo $Repo -Body $stickyBody -DryRun:$DryRun | Out-Null
        Write-Host "rubberduck-gate state: failure (chain $($advisory.Outcome) after $($advisory.Swaps) swap(s))"
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
            Add-Content -Path $env:GITHUB_OUTPUT -Value 'gate-state=failure'
            Add-Content -Path $env:GITHUB_OUTPUT -Value "head-sha=$HeadSha"
            Add-Content -Path $env:GITHUB_OUTPUT -Value "chain-outcome=$($advisory.Outcome)"
        }
        exit 1
    }

    $resolution = Resolve-RubberDuckVerdict `
        -Responses $advisory.Responses `
        -AllCopilotThreadsAddressed ([bool]$copilotTriagePlan.Summary.AllCopilotThreadsAddressed)

    $copilotGateNotes = [System.Collections.Generic.List[string]]::new()
    foreach ($thread in @($copilotTriagePlan.Summary.UnaddressedCopilotThreads)) {
        $threadId = [string]$thread.ThreadId
        $category = [string]$thread.Category
        [void]$copilotGateNotes.Add("[correctness] Copilot thread unaddressed: $threadId (category=$category)")
    }
    $combinedFindings = @($resolution.Findings + $copilotGateNotes)

    $body = Format-AdvisoryComment `
        -PRNumber $PRNumber `
        -Findings $combinedFindings `
        -Verdict $resolution.Verdict `
        -HeadSha $HeadSha `
        -Approves $resolution.Approves `
        -TotalModels $resolution.TotalModels
    Publish-AdvisoryComment -PRNumber $PRNumber -Repo $Repo -Body $body -DryRun:$DryRun | Out-Null

    # Surface gate result to the workflow so it can post the
    # `rubberduck-gate` commit status against the head SHA.
    $gateState = if ($resolution.Passed) { 'success' } else { 'failure' }
    Write-Host "rubberduck-gate state: $gateState (approves=$($resolution.Approves)/$($resolution.TotalModels), verdict=$($resolution.Verdict))"
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "gate-state=$gateState"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "head-sha=$HeadSha"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "plan-hash=$([string]$copilotTriagePlan.PlanHash)"
        $allAddressedText = ([string]$resolution.AllCopilotThreadsAddressed).ToLowerInvariant()
        Add-Content -Path $env:GITHUB_OUTPUT -Value "all-copilot-threads-addressed=$allAddressedText"
        $unaddressedJson = Remove-Credentials ((@($copilotTriagePlan.Summary.UnaddressedCopilotThreads) | ConvertTo-Json -Depth 10 -Compress))
        Add-Content -Path $env:GITHUB_OUTPUT -Value "unaddressed-copilot-threads=$unaddressedJson"
    }

    Write-Host "Advisory comment published / updated on PR #$PRNumber."
}
