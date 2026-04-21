#requires -Version 7.0
<#
.SYNOPSIS
    Track E LLM-assisted triage scaffold (issue #433). Signatures only.

.DESCRIPTION
    Phase 2 scaffold. Implementation is held behind Phase 1 MVP and the product
    validation gate. See docs/design/llm-triage.md for the full design.

    Two locked rules:
      Rule 1: rubberduck (2-of-3 consensus) is the DEFAULT; -SingleModel opts out.
      Rule 2: tier-aware model selection respects the user's Copilot plan.
#>

Set-StrictMode -Version Latest

function Invoke-CopilotTriage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Findings,

        [ValidateSet('Rubberduck', 'SingleModel')]
        [string] $Mode = 'Rubberduck',

        [ValidateSet('Pro', 'Business', 'Enterprise')]
        [string] $CopilotTier,

        [string] $ExplicitModel
    )
    throw [System.NotImplementedException]::new(
        'Invoke-CopilotTriage is a Phase 2 scaffold. See docs/design/llm-triage.md.'
    )
}

function Get-AvailableModelsFromCopilotPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pro', 'Business', 'Enterprise')]
        [string] $Tier
    )
    throw [System.NotImplementedException]::new(
        'Get-AvailableModelsFromCopilotPlan is a Phase 2 scaffold.'
    )
}

function Select-TriageTrio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $AvailableModels,

        [Parameter(Mandatory)]
        [object] $RankingTable
    )
    throw [System.NotImplementedException]::new(
        'Select-TriageTrio is a Phase 2 scaffold.'
    )
}

function Invoke-PromptSanitization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Prompt
    )
    throw [System.NotImplementedException]::new(
        'Invoke-PromptSanitization is a Phase 2 scaffold. Will delegate to Remove-Credentials.'
    )
}

function Invoke-ResponseSanitization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Response
    )
    throw [System.NotImplementedException]::new(
        'Invoke-ResponseSanitization is a Phase 2 scaffold. Will delegate to Remove-Credentials.'
    )
}

Export-ModuleMember -Function `
    Invoke-CopilotTriage, `
    Get-AvailableModelsFromCopilotPlan, `
    Select-TriageTrio, `
    Invoke-PromptSanitization, `
    Invoke-ResponseSanitization
