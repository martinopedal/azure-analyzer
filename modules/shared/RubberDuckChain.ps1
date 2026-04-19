#Requires -Version 7.4
<#
.SYNOPSIS
    Frontier-only retry + fallback chain for the rubber-duck PR review gate.

.DESCRIPTION
    Wraps a model invocation with two layers of resilience:

    1. Per-model retry layer (`Invoke-ModelWithRetry`):
       * Up to 3 attempts before giving up on the current model.
       * Exponential backoff `1s -> 4s -> 16s` with +/-25% jitter.
       * Retry triggers: HTTP 429 / 503 / 504, response body containing
         `rate_limit` / `quota_exceeded` / `overloaded` /
         `temporarily_unavailable` / `service_unavailable` / `throttle` /
         `socket timeout` / `connection reset` (case-insensitive).
       * `context_length_exceeded` short-circuits the retries and triggers
         an immediate model swap (more wait will not help).

    2. Per-call swap layer (`Invoke-RubberDuckTrio`):
       * Starts from the standard frontier trio
         (`claude-opus-4.7`, `gpt-5.3-codex`, `goldeneye`).
       * If a trio member fails, swaps to the FIRST eligible chain entry
         not already used in this call.
       * Up to 5 swaps per gate invocation.
       * Models that already returned a verdict are NEVER re-invoked
         (the "3 distinct frontier verdicts per SHA" invariant).
       * Every swap writes an audit row to
         `.squad/decisions/inbox/gate-fallback-{pr}-{sha}-{from}-to-{to}-{reason}.md`.
       * On chain exhaustion the caller posts a sticky comment
         (`Format-ChainExhaustedComment`) and exits non-zero.

    The chain itself is FRONTIER ONLY. See
    `.copilot/copilot-instructions.md` -> "Frontier Model Roster". Adding
    sonnet / haiku / mini / gpt-4.1 / opus-4.6-base / opus-4.5 / non-latest
    codex to `$script:FrontierFallbackChain` is a security incident.

.NOTES
    The model invocation itself (the inner `CallInvoker` script block) is
    still a deterministic stub in `Invoke-PRAdvisoryGate.ps1` until the
    real GitHub Models REST / `gh copilot suggest` call lands. The retry
    + swap layer is real today and exercised by Pester.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Sanitize.ps1')

# --- Constants -------------------------------------------------------------

# Strict frontier-only allow-list. Order is the fallback order.
# DO NOT add sonnet/haiku/mini/gpt-4.1/opus-4.6-base here.
$script:FrontierFallbackChain = @(
    'claude-opus-4.7',
    'claude-opus-4.6-1m',
    'gpt-5.4',
    'gpt-5.3-codex',
    'goldeneye'
)

# The 3-model gate trio at startup. Substituted from the chain on failure.
$script:DefaultRubberDuckTrio = @(
    'claude-opus-4.7',
    'gpt-5.3-codex',
    'goldeneye'
)

$script:MaxRetriesPerModel = 3
$script:MaxSwapsPerCall = 5

# --- Public accessors ------------------------------------------------------

function Get-FrontierFallbackChain {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    , @($script:FrontierFallbackChain)
}

function Get-DefaultRubberDuckTrio {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    , @($script:DefaultRubberDuckTrio)
}

# --- Error classification --------------------------------------------------

function Test-RetryableModelError {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Message = '',

        [int] $StatusCode = 0
    )

    if ($StatusCode -in 429, 503, 504) { return $true }

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    $patterns = @(
        'rate[_ ]limit',
        'quota[_ ]exceeded',
        'overloaded',
        'temporarily[_ ]unavailable',
        'service[_ ]unavailable',
        'throttl',
        'socket\s+timeout',
        'connection\s+reset',
        '\b(429|503|504)\b'
    )
    foreach ($p in $patterns) {
        if ($Message -match "(?i)$p") { return $true }
    }
    return $false
}

function Test-ContextOverflowError {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Message = ''
    )
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    [bool]($Message -match '(?i)(context[_ ]length[_ ]exceeded|context\s+length\s+exceeded|maximum\s+context|too\s+many\s+tokens)')
}

# --- Backoff ---------------------------------------------------------------

function Get-RetryBackoffSeconds {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 10)]
        [int] $Attempt,

        [double] $BaseSeconds = 1.0,

        [System.Random] $Random
    )

    # 1s -> 4s -> 16s for attempts 0/1/2.
    $delay = [math]::Pow(4.0, $Attempt) * $BaseSeconds
    if ($null -eq $Random) { $Random = [System.Random]::new() }
    # +/-25% jitter.
    $jitter = ($Random.NextDouble() * 0.5) - 0.25
    [math]::Max(0.0, $delay * (1.0 + $jitter))
}

# --- Per-model retry -------------------------------------------------------

function Invoke-ModelWithRetry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ModelName,

        [Parameter(Mandatory)]
        [hashtable] $CallContext,

        [Parameter(Mandatory)]
        [scriptblock] $CallInvoker,

        [int] $MaxRetries = $script:MaxRetriesPerModel,

        [scriptblock] $Sleep = { param($s) Start-Sleep -Seconds $s },

        [System.Random] $Random
    )

    $lastError = ''
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            $response = & $CallInvoker $ModelName $CallContext
            return [pscustomobject]@{
                Outcome  = 'Success'
                Model    = $ModelName
                Response = $response
                Attempts = $attempt + 1
                Error    = ''
            }
        } catch {
            $msg = [string]$_.Exception.Message
            $status = 0
            if ($_.Exception.PSObject.Properties['StatusCode']) {
                try { $status = [int]$_.Exception.StatusCode } catch { $status = 0 }
            }
            $lastError = $msg

            if (Test-ContextOverflowError -Message $msg) {
                return [pscustomobject]@{
                    Outcome  = 'ContextOverflow'
                    Model    = $ModelName
                    Response = $null
                    Attempts = $attempt + 1
                    Error    = Remove-Credentials $msg
                }
            }

            if (-not (Test-RetryableModelError -Message $msg -StatusCode $status)) {
                return [pscustomobject]@{
                    Outcome  = 'Fatal'
                    Model    = $ModelName
                    Response = $null
                    Attempts = $attempt + 1
                    Error    = Remove-Credentials $msg
                }
            }

            $attempt++
            if ($attempt -lt $MaxRetries) {
                $delay = Get-RetryBackoffSeconds -Attempt ($attempt - 1) -Random $Random
                & $Sleep $delay
            }
        }
    }

    [pscustomobject]@{
        Outcome  = 'Exhausted'
        Model    = $ModelName
        Response = $null
        Attempts = $attempt
        Error    = Remove-Credentials $lastError
    }
}

# --- Audit log -------------------------------------------------------------

function Write-FallbackAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $PRNumber,
        [Parameter(Mandatory)] [string] $HeadSha,
        [Parameter(Mandatory)] [string] $FromModel,
        [string] $ToModel = 'none',
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [string] $OutputPath,
        [switch] $DryRun
    )

    if ($DryRun) { return $null }

    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    $safe = { param($s) ($s -replace '[^A-Za-z0-9._-]', '-') }
    $safeFrom = & $safe $FromModel
    $safeTo = if ([string]::IsNullOrWhiteSpace($ToModel)) { 'none' } else { & $safe $ToModel }
    $safeReason = & $safe $Reason
    if ($safeReason.Length -gt 40) { $safeReason = $safeReason.Substring(0, 40) }
    $rawSha = if ([string]::IsNullOrWhiteSpace($HeadSha)) { 'no-sha' } else { ($HeadSha -replace '[^A-Za-z0-9]', '') }
    $safeSha = if ($rawSha.Length -ge 12) { $rawSha.Substring(0, 12) } else { $rawSha }

    $file = Join-Path $OutputPath "gate-fallback-$PRNumber-$safeSha-$safeFrom-to-$safeTo-$safeReason.md"

    $body = @"
# Gate fallback audit

- PR: #$PRNumber
- Head SHA: $HeadSha
- From model: $FromModel
- To model: $ToModel
- Reason: $Reason
- Time: $((Get-Date).ToUniversalTime().ToString('o'))
"@

    Set-Content -Path $file -Value (Remove-Credentials $body) -Encoding utf8
    return $file
}

# --- Sticky chain-exhausted comment ----------------------------------------

function Format-ChainExhaustedComment {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int] $PRNumber,
        [string] $HeadSha = '',
        [int] $Swaps = 0,
        [int] $RetriesPerModel = $script:MaxRetriesPerModel
    )

    $shaLine = if (-not [string]::IsNullOrWhiteSpace($HeadSha)) {
        "`n**Head SHA:** ``$HeadSha``"
    } else { '' }

    @"
<!-- squad-advisory -->
## Advisory review (3-model consensus)

[X] Gate could not reach any frontier model ($Swaps swaps x $RetriesPerModel retries exhausted). Manual review required.$shaLine

The frontier fallback chain (claude-opus-4.7 -> claude-opus-4.6-1m -> gpt-5.4 -> gpt-5.3-codex -> goldeneye) was exhausted without producing the required ``2-of-3`` distinct frontier verdicts for this commit. This is an upstream availability issue, not a code defect.

> Fail-closed: rubberduck-gate commit status is set to ``failure`` for this SHA. Push a new commit (or wait for upstream capacity to recover) to re-arm the gate.
> Audit trail: see ``.squad/decisions/inbox/gate-fallback-$PRNumber-*.md``.

_PR #$PRNumber, generated by ``pr-advisory-gate.yml`` (#157)._
"@
}

# --- Per-call swap orchestrator -------------------------------------------

function Get-NextChainCandidate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Chain,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $UsedModels,

        [string] $Failed = '',

        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $TriedAndFailed
    )

    foreach ($m in $Chain) {
        if (-not [string]::IsNullOrWhiteSpace($Failed) -and $m -ieq $Failed) { continue }
        if ($UsedModels.Contains($m)) { continue }
        if ($null -ne $TriedAndFailed -and $TriedAndFailed.Contains($m)) { continue }
        return $m
    }
    return ''
}

<#
Run the 3-model trio for one PR head SHA. Each slot picks a model from
the trio, then falls back through the frontier chain on failure. Models
that already returned a verdict are excluded from subsequent slots so
the same SHA always yields three distinct frontier verdicts (or fails
closed via ChainExhausted / SwapLimitExceeded).
#>
function Invoke-RubberDuckTrio {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [int] $PRNumber,
        [Parameter(Mandatory)] [string] $HeadSha,
        [Parameter(Mandatory)] [hashtable] $CallContext,
        [Parameter(Mandatory)] [scriptblock] $CallInvoker,

        [string] $OutputPath = '.squad/decisions/inbox/',
        [int] $MaxSwaps = $script:MaxSwapsPerCall,
        [string[]] $Trio = $script:DefaultRubberDuckTrio,
        [string[]] $Chain = $script:FrontierFallbackChain,
        [scriptblock] $Sleep = { param($s) Start-Sleep -Seconds $s },
        [System.Random] $Random,

        [switch] $DryRun
    )

    $verdicts = [System.Collections.Generic.List[pscustomobject]]::new()
    $usedModels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $triedAndFailed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $swapCount = 0

    foreach ($slotInitial in $Trio) {
        $candidate = $slotInitial
        $slotResolved = $false

        while (-not $slotResolved) {
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                return [pscustomobject]@{
                    Outcome    = 'ChainExhausted'
                    Verdicts   = @($verdicts)
                    Swaps      = $swapCount
                    UsedModels = @($usedModels)
                }
            }

            if ($usedModels.Contains($candidate) -or $triedAndFailed.Contains($candidate)) {
                $next = Get-NextChainCandidate -Chain $Chain -UsedModels $usedModels -TriedAndFailed $triedAndFailed
                if ([string]::IsNullOrWhiteSpace($next)) {
                    return [pscustomobject]@{
                        Outcome    = 'ChainExhausted'
                        Verdicts   = @($verdicts)
                        Swaps      = $swapCount
                        UsedModels = @($usedModels)
                    }
                }
                Write-FallbackAudit -PRNumber $PRNumber -HeadSha $HeadSha -FromModel $candidate -ToModel $next -Reason 'already-used' -OutputPath $OutputPath -DryRun:$DryRun | Out-Null
                $candidate = $next
                continue
            }

            $result = Invoke-ModelWithRetry `
                -ModelName $candidate `
                -CallContext $CallContext `
                -CallInvoker $CallInvoker `
                -Sleep $Sleep `
                -Random $Random

            if ($result.Outcome -eq 'Success') {
                [void]$usedModels.Add($candidate)
                [void]$verdicts.Add([pscustomobject]@{
                        Model    = $candidate
                        Response = $result.Response
                        Attempts = $result.Attempts
                    })
                $slotResolved = $true
                continue
            }

            # Failure: classify, audit, swap.
            [void]$triedAndFailed.Add($candidate)
            $swapCount++
            $reason = $result.Outcome  # ContextOverflow / Exhausted / Fatal
            $next = Get-NextChainCandidate -Chain $Chain -UsedModels $usedModels -TriedAndFailed $triedAndFailed -Failed $candidate
            Write-FallbackAudit -PRNumber $PRNumber -HeadSha $HeadSha -FromModel $candidate -ToModel $next -Reason $reason -OutputPath $OutputPath -DryRun:$DryRun | Out-Null

            if ($swapCount -gt $MaxSwaps) {
                return [pscustomobject]@{
                    Outcome    = 'SwapLimitExceeded'
                    Verdicts   = @($verdicts)
                    Swaps      = $swapCount
                    UsedModels = @($usedModels)
                }
            }

            if ([string]::IsNullOrWhiteSpace($next)) {
                return [pscustomobject]@{
                    Outcome    = 'ChainExhausted'
                    Verdicts   = @($verdicts)
                    Swaps      = $swapCount
                    UsedModels = @($usedModels)
                }
            }

            $candidate = $next
        }
    }

    [pscustomobject]@{
        Outcome    = 'Success'
        Verdicts   = @($verdicts)
        Swaps      = $swapCount
        UsedModels = @($usedModels)
    }
}
