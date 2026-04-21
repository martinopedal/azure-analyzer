#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReportArchitectureTiers = @('PureJson', 'EmbeddedSqlite', 'SidecarSqlite', 'PodeViewer')

function Get-ReportTierRank {
    param([Parameter(Mandatory)][string]$Tier)
    return [array]::IndexOf($script:ReportArchitectureTiers, $Tier)
}

function Select-ReportArchitecture {
    [CmdletBinding()]
    param(
        [int] $FindingCount = 0,
        [int] $EntityCount = 0,
        [int] $EdgeCount = 0,
        [double] $HeadroomFactor = 1.25
    )

    if ($HeadroomFactor -le 0) {
        throw "HeadroomFactor must be greater than 0."
    }

    $adjustedFindings = [int][math]::Ceiling([math]::Max(0, $FindingCount) * $HeadroomFactor)
    $adjustedEntities = [int][math]::Ceiling([math]::Max(0, $EntityCount) * $HeadroomFactor)
    $adjustedEdges = [int][math]::Ceiling([math]::Max(0, $EdgeCount) * $HeadroomFactor)

    $findingTier = if ($adjustedFindings -gt 500000) {
        'PodeViewer'
    } elseif ($adjustedFindings -ge 100000) {
        'SidecarSqlite'
    } elseif ($adjustedFindings -ge 10000) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    $entityTier = if ($adjustedEntities -gt 500000) {
        'PodeViewer'
    } elseif ($adjustedEntities -ge 100000) {
        'SidecarSqlite'
    } elseif ($adjustedEntities -ge 10000) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    $edgeTier = if ($adjustedEdges -gt 50000) {
        'PodeViewer'
    } elseif ($adjustedEdges -ge 2500) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    $pickerTier = @($findingTier, $entityTier, $edgeTier) |
        Sort-Object { Get-ReportTierRank $_ } -Descending |
        Select-Object -First 1

    $forcedTier = $env:AZURE_ANALYZER_FORCE_ARCH
    $forcedOverride = $false
    $tier = $pickerTier
    $reason = [System.Collections.Generic.List[string]]::new()
    $reason.Add("findings=>$findingTier")
    $reason.Add("entities=>$entityTier")
    $reason.Add("edges=>$edgeTier")

    if (-not [string]::IsNullOrWhiteSpace($forcedTier)) {
        if ($forcedTier -notin $script:ReportArchitectureTiers) {
            throw "AZURE_ANALYZER_FORCE_ARCH must be one of: $($script:ReportArchitectureTiers -join ', ')."
        }
        $forcedOverride = $true
        if ((Get-ReportTierRank $forcedTier) -lt (Get-ReportTierRank $pickerTier)) {
            Write-Warning "Forced architecture '$forcedTier' is below picker recommendation '$pickerTier'."
        }
        $tier = $forcedTier
        $reason.Add("forced=>$forcedTier")
    }

    return [pscustomobject]@{
        Tier           = $tier
        Reasoning      = @($reason)
        Measurements   = [pscustomobject]@{
            Findings = [math]::Max(0, $FindingCount)
            Entities = [math]::Max(0, $EntityCount)
            Edges    = [math]::Max(0, $EdgeCount)
        }
        Headroom       = [pscustomobject]@{
            Factor   = $HeadroomFactor
            Findings = $adjustedFindings
            Entities = $adjustedEntities
            Edges    = $adjustedEdges
        }
        ForcedOverride = $forcedOverride
    }
}
