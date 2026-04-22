#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReportArchitectureTiers = @('PureJson', 'EmbeddedSqlite', 'SidecarSqlite', 'PodeViewer')

function Get-DefaultReportArchitectureConfig {
    [CmdletBinding()]
    param ()

    return [pscustomobject]@{
        default_tier     = 'PureJson'
        headroom_factor  = 1.25
        thresholds       = [pscustomobject]@{
            findings = [pscustomobject]@{ embedded = 10000; sidecar = 100000; pode = 500000 }
            entities = [pscustomobject]@{ embedded = 10000; sidecar = 100000; pode = 500000 }
            edges    = [pscustomobject]@{ embedded = 2500; pode = 50000 }
        }
        vendored_dependencies = @(
            [pscustomobject]@{ name = 'cytoscape'; placeholder = $true; verify_stub = 'Test-CytoscapePlaceholder' },
            [pscustomobject]@{ name = 'dagre'; placeholder = $true; verify_stub = 'Test-DagrePlaceholder' },
            [pscustomobject]@{ name = 'pode'; placeholder = $true; verify_stub = 'Test-PodePlaceholder' },
            [pscustomobject]@{ name = 'sqlite-wasm'; placeholder = $true; verify_stub = 'Test-SqliteWasmPlaceholder' }
        )
    }
}

function Get-ReportTierRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tier)
    return [array]::IndexOf($script:ReportArchitectureTiers, $Tier)
}

function Select-ReportArchitecture {
    [CmdletBinding()]
    param(
        [int] $FindingCount = 0,
        [int] $EntityCount = 0,
        [int] $EdgeCount = 0,
        [double] $HeadroomFactor = 1.25,
        [object] $ArchitectureConfig
    )

    if ($HeadroomFactor -le 0) {
        throw "HeadroomFactor must be greater than 0."
    }

    $cfg = if ($ArchitectureConfig) { $ArchitectureConfig } else { Get-DefaultReportArchitectureConfig }
    $thresholds = $cfg.thresholds

    $rawFindings = [math]::Max(0, $FindingCount)
    $rawEntities = [math]::Max(0, $EntityCount)
    $rawEdges = [math]::Max(0, $EdgeCount)

    $adjustedFindings = [int][math]::Ceiling($rawFindings * $HeadroomFactor)
    $adjustedEntities = [int][math]::Ceiling($rawEntities * $HeadroomFactor)
    $adjustedEdges = [int][math]::Ceiling($rawEdges * $HeadroomFactor)

    $findingTier = if ($adjustedFindings -gt [int]$thresholds.findings.pode) {
        'PodeViewer'
    } elseif ($adjustedFindings -ge [int]$thresholds.findings.sidecar) {
        'SidecarSqlite'
    } elseif ($adjustedFindings -ge [int]$thresholds.findings.embedded) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    $entityTier = if ($adjustedEntities -gt [int]$thresholds.entities.pode) {
        'PodeViewer'
    } elseif ($adjustedEntities -ge [int]$thresholds.entities.sidecar) {
        'SidecarSqlite'
    } elseif ($adjustedEntities -ge [int]$thresholds.entities.embedded) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    $edgeTier = if ($adjustedEdges -gt [int]$thresholds.edges.pode) {
        'PodeViewer'
    } elseif ($adjustedEdges -ge [int]$thresholds.edges.embedded) {
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
    $reasoning = [System.Collections.Generic.List[string]]::new()
    $reasoning.Add("findings=>$findingTier")
    $reasoning.Add("entities=>$entityTier")
    $reasoning.Add("edges=>$edgeTier")

    if (-not [string]::IsNullOrWhiteSpace($forcedTier)) {
        if ($forcedTier -notin $script:ReportArchitectureTiers) {
            throw "AZURE_ANALYZER_FORCE_ARCH must be one of: $($script:ReportArchitectureTiers -join ', ')."
        }
        $forcedOverride = $true
        $tier = $forcedTier
        $reasoning.Add("forced=>$forcedTier")
    }

    return [pscustomobject]@{
        Tier           = $tier
        Reasoning      = @($reasoning)
        Measurements   = [pscustomobject]@{
            Findings = $rawFindings
            Entities = $rawEntities
            Edges    = $rawEdges
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

function Get-ReportVerificationStubs {
    [CmdletBinding()]
    param(
        [object] $ArchitectureConfig
    )

    $cfg = if ($ArchitectureConfig) { $ArchitectureConfig } else { Get-DefaultReportArchitectureConfig }
    $deps = @($cfg.vendored_dependencies)
    if (-not $deps -or $deps.Count -eq 0) {
        $deps = @((Get-DefaultReportArchitectureConfig).vendored_dependencies)
    }

    $depNames = @($deps | ForEach-Object { [string]$_.name })
    $podeDeps = @($depNames | Where-Object { $_ -eq 'pode' -or $_ -eq 'cytoscape' -or $_ -eq 'dagre' -or $_ -eq 'sqlite-wasm' })
    $sqliteDeps = @($depNames | Where-Object { $_ -eq 'cytoscape' -or $_ -eq 'dagre' -or $_ -eq 'sqlite-wasm' })

    return [pscustomobject]@{
        PureJson = [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @(); Dependencies = @() }
        EmbeddedSqlite = [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @('placeholder verification stubs active'); Dependencies = $sqliteDeps }
        SidecarSqlite = [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @('placeholder verification stubs active'); Dependencies = $sqliteDeps }
        PodeViewer = [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @('placeholder verification stubs active'); Dependencies = $podeDeps }
    }
}

function New-ReportManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SelectedTier,

        [object] $Measurements = [pscustomobject]@{},
        [double] $HeadroomFactor = 1.25,
        [string[]] $PickerReasoning = @(),
        [bool] $ForcedOverride = $false,
        [object] $VerificationResults = [pscustomobject]@{},
        [object[]] $AutoUpgrades = @(),
        [object] $Timings = [pscustomobject]@{},
        [object[]] $Features = @()
    )

    $degradations = @(
        @($Features) | Where-Object {
            $_ -and
            $_.PSObject.Properties['renderingMode'] -and
            $_.PSObject.Properties['tier1Mode'] -and
            [string]$_.renderingMode -ne [string]$_.tier1Mode
        }
    )

    $manifest = [pscustomobject]@{
        SchemaVersion       = '1.0'
        GeneratedAt         = (Get-Date).ToUniversalTime().ToString('o')
        SelectedTier        = $SelectedTier
        Measurements        = if ($Measurements) { $Measurements } else { [pscustomobject]@{} }
        HeadroomFactor      = $HeadroomFactor
        PickerReasoning     = @($PickerReasoning)
        ForcedOverride      = [bool]$ForcedOverride
        VerificationResults = if ($VerificationResults) { $VerificationResults } else { [pscustomobject]@{} }
        AutoUpgrades        = @($AutoUpgrades)
        Timings             = if ($Timings) { $Timings } else { [pscustomobject]@{} }
        Features            = @($Features)
        Degradations        = @($degradations)
    }

    $json = $manifest | ConvertTo-Json -Depth 30
    Set-Content -Path $Path -Value $json -Encoding UTF8
    return $manifest
}
