# AzAdvertizerLookup.ps1
# Track C scaffold (#431). Stub only.
# Deterministic finding-type to policy lookup. No live fetch, no telemetry.
# Catalog vendored SHA-pinned (lands in implementation PR after Foundation #435).

Set-StrictMode -Version Latest

$script:PolicyCatalogCache = @{}
$script:FindingMapCache = @{}

function Get-PolicyCatalogPath {
    param([string] $Leaf)
    return Join-Path (Join-Path $PSScriptRoot 'catalogs') $Leaf
}

function Import-PolicyCatalog {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Name catalog not found at '$Path'."
    }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ($script:PolicyCatalogCache.ContainsKey($resolved)) {
        return $script:PolicyCatalogCache[$resolved]
    }
    $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
    $catalog = $raw | ConvertFrom-Json
    if (-not $catalog.PSObject.Properties['entries']) {
        throw "$Name catalog at '$resolved' is missing entries[]."
    }
    $script:PolicyCatalogCache[$resolved] = $catalog
    return $catalog
}

function Invoke-AzAdvertizerLookup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PolicyId,
        [string] $CatalogPath = (Get-PolicyCatalogPath -Leaf 'azadvertizer-catalog.json'),
        [object] $Catalog
    )

    if ([string]::IsNullOrWhiteSpace($PolicyId)) { return $null }
    if (-not $Catalog) { $Catalog = Import-PolicyCatalog -Path $CatalogPath -Name 'AzAdvertizer' }
    return ($Catalog.entries | Where-Object { [string]$_.policyId -ieq [string]$PolicyId } | Select-Object -First 1)
}

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
    .PARAMETER Map
        Optional preloaded finding-to-policy map object (skips disk read + JSON parse).
    .PARAMETER AlzCatalog
        Optional preloaded ALZ policy catalog object (skips disk read + JSON parse).
    .PARAMETER AzAdvertizerCatalog
        Optional preloaded AzAdvertizer policy catalog object (skips disk read + JSON parse).
    .OUTPUTS
        Array of PSCustomObject { PolicyId, DisplayName, Source, ScopeHint, Url, Pill }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Finding,
        [string] $MapPath,
        [int] $MaxSuggestions = 3,
        [ValidateSet('Full','Partial','Fallback')] [string] $AlzActivation = 'Fallback',
        [object] $Map,
        [object] $AlzCatalog,
        [object] $AzAdvertizerCatalog
    )
    if ($MaxSuggestions -lt 1) { return @() }

    if (-not $Map) { $Map = Import-FindingToPolicyMap -MapPath $MapPath }
    $findingType = ''
    foreach ($candidateProp in 'FindingType', 'findingType', 'Type', 'Category') {
        if ($Finding.PSObject.Properties[$candidateProp] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.$candidateProp)) {
            $findingType = [string]$Finding.$candidateProp
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($findingType)) { return @() }

    $entry = @($Map.entries | Where-Object { [string]$_.findingType -ieq $findingType } | Select-Object -First 1)
    if (-not $entry) { return @() }

    $allowAlz = $AlzActivation -in @('Full', 'Partial')
    $suggestions = @(
        @($entry.suggestions) |
            Where-Object {
                $_ -and (
                    ([string]$_.source -eq 'AzAdvertizer') -or
                    ($allowAlz -and [string]$_.source -eq 'ALZ')
                )
            } |
            Sort-Object @{ Expression = { [int]$_.priority }; Ascending = $true }, @{ Expression = { [string]$_.source }; Ascending = $true }, @{ Expression = { [string]$_.displayName }; Ascending = $true } |
            Select-Object -First $MaxSuggestions
    )

    if (-not $AlzCatalog) {
        $AlzCatalog = Import-PolicyCatalog -Path (Get-PolicyCatalogPath -Leaf 'alz-policy-catalog.json') -Name 'ALZ'
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $suggestions) {
        $source = [string]$s.source
        $policyId = [string]$s.policyId
        $displayName = [string]$s.displayName
        $scopeHint = [string]$s.scopeHint
        $url = ''
        if ($source -eq 'AzAdvertizer') {
            $catalogHit = if ($AzAdvertizerCatalog) {
                Invoke-AzAdvertizerLookup -PolicyId $policyId -Catalog $AzAdvertizerCatalog
            } else {
                Invoke-AzAdvertizerLookup -PolicyId $policyId
            }
            if ($catalogHit) {
                if (-not [string]::IsNullOrWhiteSpace([string]$catalogHit.displayName)) { $displayName = [string]$catalogHit.displayName }
                $url = [string]$catalogHit.url
            }
        } elseif ($source -eq 'ALZ') {
            $catalogHit = @($AlzCatalog.entries | Where-Object { [string]$_.policyId -ieq $policyId } | Select-Object -First 1)
            if ($catalogHit) {
                if (-not [string]::IsNullOrWhiteSpace([string]$catalogHit.displayName)) { $displayName = [string]$catalogHit.displayName }
                $url = [string]$catalogHit.url
            }
        }

        if ([string]::IsNullOrWhiteSpace($url) -and $source -eq 'AzAdvertizer') {
            if ($policyId -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $url = "https://www.azadvertizer.net/azpolicyadvertizer/$($Matches[1].ToLowerInvariant()).html"
            }
        }

        $rows.Add([pscustomobject]@{
            PolicyId    = $policyId
            DisplayName = $displayName
            Source      = $source
            ScopeHint   = $scopeHint
            Url         = $url
            Pill        = if ($source -eq 'ALZ') { 'ALZ' } elseif ($source -eq 'AzAdvertizer') { 'AzAdvertizer' } else { 'built-in' }
        }) | Out-Null
    }

    return @($rows)
}

function Import-FindingToPolicyMap {
    <#
    .SYNOPSIS
        Load and validate the curated finding-to-policy mapping table.
    #>
    [CmdletBinding()]
    param([string] $MapPath)
    if ([string]::IsNullOrWhiteSpace($MapPath)) {
        $MapPath = Join-Path $PSScriptRoot 'finding-to-policy-map.json'
    }
    if (-not (Test-Path -LiteralPath $MapPath)) {
        throw "finding-to-policy map not found at '$MapPath'."
    }
    $resolved = (Resolve-Path -LiteralPath $MapPath).ProviderPath
    if ($script:FindingMapCache.ContainsKey($resolved)) {
        return $script:FindingMapCache[$resolved]
    }

    $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
    $map = $raw | ConvertFrom-Json
    if (-not $map.PSObject.Properties['entries']) {
        throw "finding-to-policy map '$resolved' is missing entries[]."
    }
    foreach ($entry in @($map.entries)) {
        if (-not $entry.PSObject.Properties['findingType'] -or [string]::IsNullOrWhiteSpace([string]$entry.findingType)) {
            throw "finding-to-policy map '$resolved' contains an entry without findingType."
        }
        if (-not $entry.PSObject.Properties['suggestions']) {
            throw "finding-to-policy map '$resolved' entry '$($entry.findingType)' is missing suggestions[]."
        }
    }
    $script:FindingMapCache[$resolved] = $map
    return $map
}

function Get-CatalogVintage {
    <#
    .SYNOPSIS
        Return catalog SHA + vintage date for both AzAdvertizer and ALZ.
    #>
    [CmdletBinding()]
    param()
    $map = Import-FindingToPolicyMap
    $azCatalog = Import-PolicyCatalog -Path (Get-PolicyCatalogPath -Leaf 'azadvertizer-catalog.json') -Name 'AzAdvertizer'
    $alzCatalog = Import-PolicyCatalog -Path (Get-PolicyCatalogPath -Leaf 'alz-policy-catalog.json') -Name 'ALZ'
    $alzVintage = Get-Content -LiteralPath (Get-PolicyCatalogPath -Leaf 'alz-vintage.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    return [pscustomobject]@{
        azAdvertizer = [pscustomobject]@{
            catalogVintage = [string]$map.catalogVintage.azAdvertizer.date
            catalogSha     = [string]$azCatalog.source.sha
        }
        alz = [pscustomobject]@{
            catalogVintage = [string]$alzVintage.date
            catalogSha     = [string]$alzCatalog.source.sha
        }
    }
}

if ($MyInvocation.MyCommand.Module) {
    Export-ModuleMember -Function Invoke-AzAdvertizerLookup, Get-PolicySuggestionsForFinding, Import-FindingToPolicyMap, Get-CatalogVintage
}
