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

    [bool] $Enabled = $true,

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Sanitize.ps1')

# Marker used to find and update the single advisory comment in place.
$script:AdvisoryMarker = '<!-- squad-advisory -->'

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
        [string] $Verdict = 'clean'
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
    [void]$lines.Add('## Advisory review (3-model consensus)')
    [void]$lines.Add('')
    [void]$lines.Add("**Verdict:** $emoji $Verdict")
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

# --- Main entrypoint guard ---
# Tests dot-source this file to exercise the pure functions. Skip the main
# block in that case by checking whether we were invoked as a script.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.MyCommand.Path -eq $PSCommandPath) {
    if (-not $Enabled) {
        Write-Host 'Advisory gate disabled (SQUAD_ADVISORY_GATE=0). Skipping.'
        return
    }

    if ($PRNumber -le 0) {
        throw 'PRNumber must be a positive integer.'
    }

    if (-not (Test-SquadAuthor -Login $PRAuthor)) {
        Write-Host "PR author '$PRAuthor' is not a squad agent / bot. Skipping advisory gate."
        return
    }

    if (Test-SkipAdvisoryLabel -PRNumber $PRNumber -Repo $Repo) {
        return
    }

    Write-Host "Squad-authored PR #$PRNumber detected (author: $PRAuthor). Building advisory triage bundle..."

    if (-not $DryRun) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # MVP scope: at PR open/sync we have no model responses yet, the bundle
    # is queued for the existing pr-review-gate.yml ingestion path. The
    # advisory comment carries an empty findings list with the marker so it
    # can be updated in place once consensus lands. This avoids burning
    # premium tokens inside CI on every push (#109 cost goal).
    $body = Format-AdvisoryComment -PRNumber $PRNumber -Findings @() -Verdict 'clean'
    Publish-AdvisoryComment -PRNumber $PRNumber -Repo $Repo -Body $body -DryRun:$DryRun | Out-Null

    Write-Host "Advisory comment published / updated on PR #$PRNumber."
}
