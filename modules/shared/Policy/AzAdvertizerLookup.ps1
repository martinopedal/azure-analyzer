# AzAdvertizerLookup.ps1
# Track C scaffold (#431). Stub only.
# Deterministic finding-type to policy lookup. No live fetch, no telemetry.
# Catalog vendored SHA-pinned (lands in implementation PR after Foundation #435).

Set-StrictMode -Version Latest

function Get-PolicySuggestionsForFinding {
    <#
    .SYNOPSIS
        Return up to N suggested policies for a given finding.
    .PARAMETER Finding
        v2 FindingRow.
    .PARAMETER MapPath
        Path to finding-to-policy-map.json. Defaults to module-relative path.
    .PARAMETER MaxSuggestions
        Maximum number of suggestions to return. Default 3.
    .PARAMETER AlzActivation
        Full | Partial | Fallback. Controls whether ALZ-source entries are returned.
    .OUTPUTS
        Array of PSCustomObject { PolicyId, DisplayName, Source, ScopeHint, Url, Pill }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Finding,
        [string] $MapPath,
        [int] $MaxSuggestions = 3,
        [ValidateSet('Full','Partial','Fallback')] [string] $AlzActivation = 'Fallback'
    )
    throw [System.NotImplementedException]::new('AzAdvertizerLookup scaffold (#431). Implementation pending Foundation #435.')
}

function Import-FindingToPolicyMap {
    <#
    .SYNOPSIS
        Load and validate the curated finding-to-policy mapping table.
    #>
    [CmdletBinding()]
    param([string] $MapPath)
    throw [System.NotImplementedException]::new('AzAdvertizerLookup scaffold (#431).')
}

function Get-CatalogVintage {
    <#
    .SYNOPSIS
        Return catalog SHA + vintage date for both AzAdvertizer and ALZ.
    #>
    [CmdletBinding()]
    param()
    throw [System.NotImplementedException]::new('AzAdvertizerLookup scaffold (#431).')
}

Export-ModuleMember -Function Get-PolicySuggestionsForFinding, Import-FindingToPolicyMap, Get-CatalogVintage
