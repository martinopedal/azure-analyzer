#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'Sanitize.ps1')
. (Join-Path $PSScriptRoot '..' 'Schema.ps1')
. (Join-Path $PSScriptRoot '..' 'Retry.ps1')

# Frontier-only triage roster (per .copilot Frontier Fallback Chain).
# Non-frontier models (sonnet, haiku, mini, gpt-4.1, gpt-5.2, gemini, opus-4.6)
# are explicitly excluded. All three tiers below MUST stay frontier-only.
$script:TierModelRosters = @{
    Pro        = @('claude-opus-4.7', 'gpt-5.4', 'goldeneye')
    Business   = @('claude-opus-4.7', 'claude-opus-4.6-1m', 'gpt-5.4', 'gpt-5.3-codex', 'goldeneye')
    Enterprise = @('claude-opus-4.7', 'claude-opus-4.6-1m', 'gpt-5.4', 'gpt-5.3-codex', 'goldeneye')
}
$script:KnownTriageModels = @($script:TierModelRosters.Values | ForEach-Object { $_ } | Select-Object -Unique)

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
    if (Get-Command -Name New-FindingError -ErrorAction SilentlyContinue) {
        return New-FindingError -Source 'triage' -Category $Category -Reason $Reason -Remediation $Remediation -Details $Details
    }
    return [PSCustomObject]@{
        PSTypeName  = 'AzureAnalyzer.FindingError'
        Source      = 'triage'
        Category    = $Category
        Reason      = $Reason
        Remediation = $Remediation
        Details     = (Remove-Credentials ([string]$Details))
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
                    $s = $s.Substring(0, $script:MaxPromptFieldChars) + '...[TRUNCATED]'
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
        1) parse `gh copilot status` for model ids
        2) fallback to `-CopilotTier`
        3) fallback to `AZURE_ANALYZER_COPILOT_TIER`
        Throws when no tier can be resolved and no models are discoverable.
    .OUTPUTS
        String[] model ids available for the resolved plan/tier.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Pro', 'Business', 'Enterprise')]
        [string] $CopilotTier
    )

    $detectedTier = ''
    $statusText = ''
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
            $detectedTier = $tierMatch.Groups[1].Value
        }

        $discovered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($m in [regex]::Matches($statusText, '(?i)\b[a-z0-9]+(?:[-.][a-z0-9]+)+\b')) {
            $token = [string]$m.Value
            if ($script:KnownTriageModels -contains $token) {
                [void]$discovered.Add($token)
            }
        }
        if ($discovered.Count -gt 0) {
            return @($discovered | Sort-Object)
        }
    }

    $resolvedTier = if (-not [string]::IsNullOrWhiteSpace($CopilotTier)) {
        $CopilotTier
    } elseif (-not [string]::IsNullOrWhiteSpace($detectedTier)) {
        $detectedTier
    } elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_ANALYZER_COPILOT_TIER)) {
        [string]$env:AZURE_ANALYZER_COPILOT_TIER
    } else {
        ''
    }

    if ([string]::IsNullOrWhiteSpace($resolvedTier)) {
        throw (New-TriageError -Category 'TierUnresolved' `
            -Reason 'Unable to resolve Copilot tier from "gh copilot status".' `
            -Remediation 'Provide -CopilotTier (Pro|Business|Enterprise) or set AZURE_ANALYZER_COPILOT_TIER.')
    }

    if (-not $script:TierModelRosters.ContainsKey($resolvedTier)) {
        throw (New-TriageError -Category 'TierUnsupported' `
            -Reason "Unsupported Copilot tier '$resolvedTier'." `
            -Remediation 'Expected Pro, Business, or Enterprise.')
    }

    return @($script:TierModelRosters[$resolvedTier])
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
            -Remediation 'Ensure your tier roster lists at least one frontier model present in the ranking config.')
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
        with the ranking config (frontier-only).
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
        Invoke an LLM scriptblock walking the Frontier Fallback Chain on
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
        -Reason 'Every model in the frontier fallback chain failed.' `
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

        [string] $ExplicitModel,

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

    $availableModels = if (-not [string]::IsNullOrWhiteSpace($CopilotTier)) {
        @(Get-AvailableModelsFromCopilotPlan -CopilotTier $CopilotTier)
    } else {
        @(Get-AvailableModelsFromCopilotPlan)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExplicitModel) -and $availableModels -notcontains $ExplicitModel) {
        $list = ($availableModels -join ', ')
        throw (New-TriageError -Category 'ExplicitModelUnavailable' `
            -Reason "Explicit model '$ExplicitModel' is not available for this Copilot tier." `
            -Remediation "Choose one of: $list, or omit -ExplicitModel.")
    }

    $selected = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitModel)) {
        $selected = @($ExplicitModel)
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
