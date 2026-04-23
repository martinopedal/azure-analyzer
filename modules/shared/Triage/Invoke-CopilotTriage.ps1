#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'Sanitize.ps1')
. (Join-Path $PSScriptRoot '..' 'Schema.ps1')
. (Join-Path $PSScriptRoot '..' 'Retry.ps1')

# Schema version for the structured triage output object.
$script:TriageSchemaVersion = '1.0'

# Allow-listed finding fields used to build prompts. Untrusted finding text is
# truncated to mitigate prompt-injection (goldeneye finding).
$script:AllowedPromptFields = @('Id', 'RuleId', 'Title', 'Severity', 'Tool', 'Platform', 'EntityType', 'EntityId', 'Pillar')
$script:MaxPromptFieldChars = 2000

function New-TriageError {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Reason,
        [string] $Remediation,
        [string] $Details
    )
    # Triage uses a domain-specific category vocabulary
    # (TierUnresolved/AllModelsFailed/NoRankedModels/...) that intentionally
    # does NOT overlap the canonical FindingErrorCategories enum in
    # modules/shared/Errors.ps1. We therefore construct the rich error inline
    # rather than delegating to New-FindingError, but mirror the same
    # sanitization invariant: every free-text field passes through
    # Remove-Credentials so the object is safe to log or throw. (See #671 for
    # why we no longer rely on a Schema.ps1 alias of New-FindingError.)
    return [PSCustomObject]@{
        PSTypeName   = 'AzureAnalyzer.FindingError'
        Source       = 'triage'
        Category     = $Category
        Reason       = (Remove-Credentials ([string]$Reason))
        Remediation  = (Remove-Credentials ([string]$Remediation))
        Details      = (Remove-Credentials ([string]$Details))
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-PromptSanitization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Prompt
    )
    Remove-Credentials $Prompt
}

function Invoke-ResponseSanitization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Response
    )
    Remove-Credentials $Response
}

function ConvertTo-SafeFindingProjection {
    <#
    .SYNOPSIS
        Project untrusted finding payloads down to the allow-listed field set
        and truncate per-field strings to mitigate prompt-injection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Findings
    )
    $projected = foreach ($f in $Findings) {
        $row = [ordered]@{}
        foreach ($field in $script:AllowedPromptFields) {
            $val = $null
            try {
                if ($f -is [hashtable] -and $f.ContainsKey($field)) { $val = $f[$field] }
                elseif ($f.PSObject.Properties.Name -contains $field) { $val = $f.$field }
            } catch { $val = $null }
            if ($null -ne $val) {
                $s = [string]$val
                if ($s.Length -gt $script:MaxPromptFieldChars) {
                    # Subtract suffix length so the total post-truncation
                    # string respects MaxPromptFieldChars exactly.
                    $suffix     = '...[TRUNCATED]'
                    $sliceLen   = [Math]::Max(0, $script:MaxPromptFieldChars - $suffix.Length)
                    $s = $s.Substring(0, $sliceLen) + $suffix
                }
                $row[$field] = $s
            }
        }
        [pscustomobject]$row
    }
    return ,@($projected)
}

function Get-AvailableModelsFromCopilotPlan {
    <#
    .SYNOPSIS
        Resolves available Copilot models for triage.
    .DESCRIPTION
        Discovery order is:
        1) resolve tier from `gh copilot status` unless -CopilotTier is provided
        2) enumerate available models from `gh copilot models list`
        Throws when tier or model discovery cannot be resolved.
    .OUTPUTS
        PSCustomObject with .Tier (string) and .Models (string[]) for the resolved plan.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Pro', 'Business', 'Enterprise')]
        [string] $CopilotTier
    )

    $resolvedTier = ''
    if (-not [string]::IsNullOrWhiteSpace($CopilotTier)) {
        $resolvedTier = $CopilotTier
    }

    $statusText = ''
    if ([string]::IsNullOrWhiteSpace($resolvedTier)) {
        try {
            $statusText = (& gh copilot status 2>$null | Out-String)
            if ($LASTEXITCODE -ne 0) {
                $statusText = ''
            }
        } catch {
            $statusText = ''
        }
        if (-not [string]::IsNullOrWhiteSpace($statusText)) {
            $tierMatch = [regex]::Match($statusText, '(?im)\b(Pro|Business|Enterprise)\b')
            if ($tierMatch.Success) {
                $resolvedTier = $tierMatch.Groups[1].Value
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedTier)) {
        throw (New-TriageError -Category 'TierUnresolved' `
            -Reason 'Unable to resolve Copilot tier from "gh copilot status".' `
            -Remediation 'Provide -CopilotTier (Pro|Business|Enterprise) when gh CLI cannot report Copilot status.')
    }

    $discovered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $listJson = ''
    $discoveryError = ''
    try {
        $listJson = (& gh copilot models list --json id 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($listJson)) {
            foreach ($m in @($listJson | ConvertFrom-Json -Depth 5)) {
                if ($m -and $m.PSObject.Properties['id']) {
                    $id = [string]$m.id
                    if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$discovered.Add($id) }
                }
            }
        }
    } catch {
        $discoveryError = [string]$_.Exception.Message
        $listJson = ''
    }

    if ($discovered.Count -eq 0) {
        throw (New-TriageError -Category 'ModelDiscoveryFailed' `
            -Reason 'Unable to discover available Copilot models from "gh copilot models list".' `
            -Remediation 'Upgrade GitHub CLI with Copilot extension support, ensure you are signed in, and retry.' `
            -Details $discoveryError)
    }

    return [pscustomobject]@{
        Tier   = $resolvedTier
        Models = @($discovered | Sort-Object)
    }
}

function Select-TriageTrio {
    <#
    .SYNOPSIS
        Selects the triage trio from available models.
    .DESCRIPTION
        Scores all 3-model combinations using weighted ranking from
        `config/triage-model-ranking.json` (sum(rank) dominates), then applies
        provider diversity as tie-break by preferring combinations with more
        unique providers. Returns top 3 models in rank order. If fewer than
        three ranked models are available, returns ranked fallback list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $AvailableModels,

        [Parameter(Mandatory)]
        [object] $RankingTable
    )

    $rankings = @($RankingTable.rankings)
    $available = @($AvailableModels | Select-Object -Unique)
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($model in $available) {
        $r = @($rankings | Where-Object { [string]$_.model -eq $model } | Select-Object -First 1)
        if ($r.Count -eq 0) { continue }
        $candidates.Add([pscustomobject]@{
                Model    = [string]$r[0].model
                Rank     = [int]$r[0].rank
                Provider = [string]$r[0].provider
            }) | Out-Null
    }

    if ($candidates.Count -eq 0) {
        throw (New-TriageError -Category 'NoRankedModels' `
            -Reason 'No available models matched config/triage-model-ranking.json.' `
            -Remediation 'Ensure config/triage-model-ranking.json includes at least one model from your Copilot roster.')
    }

    if ($candidates.Count -lt 3) {
        return @($candidates | Sort-Object @{ Expression = 'Rank'; Descending = $true }, @{ Expression = 'Model'; Descending = $false } | ForEach-Object { $_.Model })
    }

    $best = $null
    $bestScore = [int]::MinValue
    $bestModelsKey = ''
    for ($i = 0; $i -lt $candidates.Count - 2; $i++) {
        for ($j = $i + 1; $j -lt $candidates.Count - 1; $j++) {
            for ($k = $j + 1; $k -lt $candidates.Count; $k++) {
                $combo = @($candidates[$i], $candidates[$j], $candidates[$k])
                $rankScore = ($combo | Measure-Object -Property Rank -Sum).Sum
                $providerDiversity = (@($combo | Select-Object -ExpandProperty Provider -Unique)).Count
                $score = ($rankScore * 1000) + $providerDiversity
                $modelsKey = (@($combo | Select-Object -ExpandProperty Model | Sort-Object) -join '|')
                if ($score -gt $bestScore -or ($score -eq $bestScore -and $modelsKey -lt $bestModelsKey)) {
                    $bestScore = $score
                    $best = $combo
                    $bestModelsKey = $modelsKey
                }
            }
        }
    }

    @($best | Sort-Object @{ Expression = 'Rank'; Descending = $true }, @{ Expression = 'Model'; Descending = $false } | ForEach-Object { $_.Model })
}

function Get-FrontierFallbackChain {
    <#
    .SYNOPSIS
        Return the rank-ordered fallback walk for a given roster, intersected
        with the ranking config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $AvailableModels,
        [Parameter(Mandatory)][object]   $RankingTable
    )
    $rankings = @($RankingTable.rankings)
    $available = @($AvailableModels | Select-Object -Unique)
    $ordered = $rankings | Where-Object { $available -contains [string]$_.model } |
        Sort-Object @{ Expression = 'rank'; Descending = $true }, @{ Expression = 'model'; Descending = $false }
    return @($ordered | ForEach-Object { [string]$_.model })
}

function Invoke-ModelWithFallback {
    <#
    .SYNOPSIS
        Invoke an LLM scriptblock walking the rank-ordered fallback chain on
        transient failures. Each individual call is wrapped in Invoke-WithRetry
        for jittered backoff retries against transient HTTP categories.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $ModelChain,
        [Parameter(Mandatory)][scriptblock] $Invoker
    )
    $lastErr = $null
    foreach ($model in $ModelChain) {
        try {
            return Invoke-WithRetry -MaxAttempts 3 -ScriptBlock { & $Invoker $model }
        } catch {
            $lastErr = $_
            Write-Verbose "Triage fallback: model '$model' failed, walking chain. $($_.Exception.Message)"
            continue
        }
    }
    throw (New-TriageError -Category 'AllModelsFailed' `
        -Reason 'Every model in the fallback chain failed.' `
        -Remediation 'Inspect Verbose output, check Copilot quota, or rerun later.' `
        -Details ([string]$lastErr))
}

function Invoke-CopilotTriage {
    <#
    .SYNOPSIS
        Builds sanitized model selection context for LLM triage.
    .DESCRIPTION
        SCAFFOLD (preview): does not perform live model invocations. Produces a
        sanitized prompt + selection plan suitable for a downstream live caller.
        Live wiring is tracked separately so the orchestrator path stays gated
        behind -EnableAiTriage.

        Rubberduck mode is default. `-SingleModel` (or `-Mode SingleModel`)
        explicitly opts out and emits a warning. Prompt and response payloads
        are always sanitized via `Remove-Credentials`. Untrusted finding fields
        are projected to an allow-list and per-field truncated to mitigate
        prompt-injection.
    .OUTPUTS
        PSCustomObject (SchemaVersion=1.0) with:
          - SchemaVersion (string)
          - Mode ('Rubberduck'|'SingleModel')
          - SelectedModels (string[])
          - AvailableModels (string[])
          - FallbackChain (string[]) frontier walk order
          - Prompt (sanitized string built from allow-listed fields)
          - Response (sanitized string)
          - GeneratedAt (UTC ISO-8601)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Findings,

        [ValidateSet('Rubberduck', 'SingleModel')]
        [string] $Mode = 'Rubberduck',

        [ValidateSet('Pro', 'Business', 'Enterprise')]
        [string] $CopilotTier,

        [ValidatePattern('^(?i)(Auto|Explicit:.+)$')]
        [string] $TriageModel = 'Auto',

        [switch] $SingleModel,

        [string] $RankingPath = (Join-Path $PSScriptRoot '..' '..' '..' 'config' 'triage-model-ranking.json'),

        [string] $MockModelResponse
    )

    if ($Mode -eq 'SingleModel') { $SingleModel = $true }

    if (-not (Test-Path -LiteralPath $RankingPath)) {
        throw (New-TriageError -Category 'RankingFileMissing' `
            -Reason "Ranking file not found: $RankingPath" `
            -Remediation 'Restore config/triage-model-ranking.json from source control.')
    }
    $rankingTable = Get-Content -LiteralPath $RankingPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10

    $discovery = if (-not [string]::IsNullOrWhiteSpace($CopilotTier)) {
        Get-AvailableModelsFromCopilotPlan -CopilotTier $CopilotTier
    } else {
        Get-AvailableModelsFromCopilotPlan
    }
    $availableModels = @($discovery.Models)

    $explicitSelection = ''
    if ($TriageModel -match '^(?i)Explicit:(.+)$') {
        $explicitSelection = [string]$Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($explicitSelection)) {
            throw (New-TriageError -Category 'ExplicitModelInvalid' `
                -Reason 'TriageModel Explicit: value is empty.' `
                -Remediation 'Use -TriageModel Auto or -TriageModel Explicit:<model-id>.')
        }
    } elseif ($TriageModel -notmatch '^(?i)Auto$') {
        throw (New-TriageError -Category 'TriageModelInvalid' `
            -Reason "Unsupported TriageModel '$TriageModel'." `
            -Remediation 'Use -TriageModel Auto or -TriageModel Explicit:<model-id>.')
    }

    if (-not [string]::IsNullOrWhiteSpace($explicitSelection) -and $availableModels -notcontains $explicitSelection) {
        $list = ($availableModels -join ', ')
        throw (New-TriageError -Category 'ExplicitModelUnavailable' `
            -Reason "Explicit model '$explicitSelection' is not available for this Copilot roster." `
            -Remediation "Choose one of: $list, or use -TriageModel Auto.")
    }

    $selected = @()
    if (-not [string]::IsNullOrWhiteSpace($explicitSelection)) {
        $selected = @($explicitSelection)
    } elseif ($SingleModel) {
        Write-Warning 'Single-model mode enabled: opting out of default rubberduck consensus.'
        $selected = @((Select-TriageTrio -AvailableModels $availableModels -RankingTable $rankingTable)[0])
    } else {
        $selected = @(Select-TriageTrio -AvailableModels $availableModels -RankingTable $rankingTable)
        if ($selected.Count -lt 3) {
            throw (New-TriageError -Category 'InsufficientRoster' `
                -Reason 'Rubberduck mode requires at least three available models.' `
                -Remediation 'Re-run with -SingleModel to opt out explicitly, or upgrade Copilot tier.')
        }
        $selected = @($selected[0..2])
    }

    $fallbackChain = @(Get-FrontierFallbackChain -AvailableModels $availableModels -RankingTable $rankingTable)

    $safeProjection = ConvertTo-SafeFindingProjection -Findings $Findings
    $rawPrompt = ($safeProjection | ConvertTo-Json -Depth 5)
    $safePrompt = Invoke-PromptSanitization -Prompt $rawPrompt
    $rawResponse = if ($PSBoundParameters.ContainsKey('MockModelResponse')) {
        $MockModelResponse
    } else {
        # Scaffold: no live model call. Echo the selection plan only.
        "SelectedModels=$($selected -join ',')"
    }
    $safeResponse = Invoke-ResponseSanitization -Response $rawResponse

    [pscustomobject]@{
        SchemaVersion   = $script:TriageSchemaVersion
        Mode            = if ($SingleModel -or $selected.Count -eq 1) { 'SingleModel' } else { 'Rubberduck' }
        SelectedModels  = @($selected)
        AvailableModels = @($availableModels)
        FallbackChain   = $fallbackChain
        Prompt          = $safePrompt
        Response        = $safeResponse
        GeneratedAt     = (Get-Date).ToUniversalTime().ToString('o')
    }
}
