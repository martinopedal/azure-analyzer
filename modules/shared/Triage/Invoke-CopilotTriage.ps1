#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'Sanitize.ps1')

$script:TierModelRosters = @{
    Pro        = @('claude-sonnet-4.6', 'gpt-5.2', 'claude-haiku-4.5', 'gpt-4.1')
    Business   = @('claude-sonnet-4.6', 'gpt-5.2-codex', 'gpt-5.2', 'gemini-3-pro-preview', 'claude-haiku-4.5', 'gpt-4.1')
    Enterprise = @('claude-opus-4.6', 'claude-sonnet-4.6', 'gpt-5.2-codex', 'gpt-5.2', 'gemini-3-pro-preview', 'claude-haiku-4.5', 'gpt-4.1')
}
$script:KnownTriageModels = @($script:TierModelRosters.Values | ForEach-Object { $_ } | Select-Object -Unique)

function Invoke-PromptSanitization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Prompt
    )
    Remove-Credentials $Prompt
}

function Invoke-ResponseSanitization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Response
    )
    Remove-Credentials $Response
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
        throw 'Unable to resolve Copilot tier from "gh copilot status". Provide -CopilotTier (Pro|Business|Enterprise) or set AZURE_ANALYZER_COPILOT_TIER.'
    }

    if (-not $script:TierModelRosters.ContainsKey($resolvedTier)) {
        throw "Unsupported Copilot tier '$resolvedTier'. Expected Pro, Business, or Enterprise."
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
        throw 'No available models matched config/triage-model-ranking.json.'
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

function Invoke-CopilotTriage {
    <#
    .SYNOPSIS
        Builds sanitized model selection context for LLM triage.
    .DESCRIPTION
        Rubberduck mode is default. `-SingleModel` (or `-Mode SingleModel`)
        explicitly opts out and emits a warning. Prompt and response payloads
        are always sanitized via `Remove-Credentials`.
    .OUTPUTS
        PSCustomObject with:
          - Mode ('Rubberduck'|'SingleModel')
          - SelectedModels (string[])
          - AvailableModels (string[])
          - Prompt (sanitized string)
          - Response (sanitized string)
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
        throw "Ranking file not found: $RankingPath"
    }
    $rankingTable = Get-Content -LiteralPath $RankingPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10

    $availableModels = if (-not [string]::IsNullOrWhiteSpace($CopilotTier)) {
        @(Get-AvailableModelsFromCopilotPlan -CopilotTier $CopilotTier)
    } else {
        @(Get-AvailableModelsFromCopilotPlan)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExplicitModel) -and $availableModels -notcontains $ExplicitModel) {
        $list = ($availableModels -join ', ')
        throw "Explicit model '$ExplicitModel' is not available for this Copilot tier. Available models: $list"
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
            throw 'Rubberduck mode requires at least three available models. Re-run with -SingleModel to opt out explicitly.'
        }
        $selected = @($selected[0..2])
    }

    $rawPrompt = ($Findings | ConvertTo-Json -Depth 20)
    $safePrompt = Invoke-PromptSanitization -Prompt $rawPrompt
    $rawResponse = if ($PSBoundParameters.ContainsKey('MockModelResponse')) {
        $MockModelResponse
    } else {
        "SelectedModels=$($selected -join ','); Prompt=$rawPrompt"
    }
    $safeResponse = Invoke-ResponseSanitization -Response $rawResponse

    [pscustomobject]@{
        Mode            = if ($SingleModel -or $selected.Count -eq 1) { 'SingleModel' } else { 'Rubberduck' }
        SelectedModels  = @($selected)
        AvailableModels = @($availableModels)
        Prompt          = $safePrompt
        Response        = $safeResponse
    }
}
