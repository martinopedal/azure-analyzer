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
            [pscustomobject]@{ name = 'cytoscape'; placeholder = $true; verify_stub = 'Test-CytoscapePlaceholder'; applicable_tiers = @('EmbeddedSqlite', 'SidecarSqlite', 'PodeViewer') },
            [pscustomobject]@{ name = 'dagre'; placeholder = $true; verify_stub = 'Test-DagrePlaceholder'; applicable_tiers = @('EmbeddedSqlite', 'SidecarSqlite', 'PodeViewer') },
            [pscustomobject]@{ name = 'Pode'; placeholder = $true; verify_stub = 'Test-PodePlaceholder'; applicable_tiers = @('PodeViewer') },
            [pscustomobject]@{ name = 'sqlite-wasm'; placeholder = $true; verify_stub = 'Test-SqliteWasmPlaceholder'; applicable_tiers = @('EmbeddedSqlite', 'SidecarSqlite', 'PodeViewer') }
        )
    }
}

# Placeholder verifiers report Success=$false with Status='placeholder' so downstream
# tier-selection code does NOT mistake an unbundled dep for a healthy one. They are
# replaced by real verifiers in the matching dep PRs (#467 viewer, future SQLite tier).
function Test-CytoscapePlaceholder {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Success = $false; Status = 'placeholder'; Reason = 'cytoscape vendored dependency not yet bundled'; Warning = 'placeholder' }
}

function Test-DagrePlaceholder {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Success = $false; Status = 'placeholder'; Reason = 'dagre vendored dependency not yet bundled'; Warning = 'placeholder' }
}

function Test-PodePlaceholder {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Success = $false; Status = 'placeholder'; Reason = 'Pode vendored dependency not yet bundled'; Warning = 'placeholder' }
}

function Test-SqliteWasmPlaceholder {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ Success = $false; Status = 'placeholder'; Reason = 'sqlite-wasm vendored dependency not yet bundled'; Warning = 'placeholder' }
}

function Test-ReportArchitectureConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Config)

    if (-not $Config) { throw 'ArchitectureConfig is null.' }
    if (-not $Config.PSObject.Properties['thresholds']) { throw 'ArchitectureConfig.thresholds missing.' }
    $t = $Config.thresholds
    foreach ($axis in 'findings','entities') {
        if (-not $t.PSObject.Properties[$axis]) { throw "ArchitectureConfig.thresholds.$axis missing." }
        $axisCfg = $t.$axis
        foreach ($lvl in 'embedded','sidecar','pode') {
            if (-not $axisCfg.PSObject.Properties[$lvl]) { throw "ArchitectureConfig.thresholds.$axis.$lvl missing." }
            $val = $axisCfg.$lvl
            if ($null -eq $val) { throw "ArchitectureConfig.thresholds.$axis.$lvl is null." }
            if ([int]$val -le 0) { throw "ArchitectureConfig.thresholds.$axis.$lvl must be > 0 (received $val)." }
        }
        if (-not ([int]$axisCfg.embedded -lt [int]$axisCfg.sidecar -and [int]$axisCfg.sidecar -lt [int]$axisCfg.pode)) {
            throw "ArchitectureConfig.thresholds.$axis must be strictly monotonic (embedded<sidecar<pode)."
        }
    }
    if (-not $t.PSObject.Properties['edges']) { throw 'ArchitectureConfig.thresholds.edges missing.' }
    foreach ($lvl in 'embedded','pode') {
        if (-not $t.edges.PSObject.Properties[$lvl]) { throw "ArchitectureConfig.thresholds.edges.$lvl missing." }
        if ([int]$t.edges.$lvl -le 0) { throw "ArchitectureConfig.thresholds.edges.$lvl must be > 0." }
    }
    if (-not ([int]$t.edges.embedded -lt [int]$t.edges.pode)) {
        throw 'ArchitectureConfig.thresholds.edges must satisfy embedded<pode.'
    }
    if ($Config.PSObject.Properties['default_tier'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.default_tier)) {
        if ($Config.default_tier -notin $script:ReportArchitectureTiers) {
            throw "ArchitectureConfig.default_tier must be one of: $($script:ReportArchitectureTiers -join ', '). Received: $($Config.default_tier)."
        }
    }
    if ($Config.PSObject.Properties['headroom_factor'] -and $null -ne $Config.headroom_factor) {
        if ([double]$Config.headroom_factor -le 0) {
            throw "ArchitectureConfig.headroom_factor must be > 0."
        }
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
        throw "HeadroomFactor must be a positive number (>0), received: $HeadroomFactor."
    }

    $cfg = if ($ArchitectureConfig) { $ArchitectureConfig } else { Get-DefaultReportArchitectureConfig }
    Test-ReportArchitectureConfig -Config $cfg

    # Honor manifest headroom_factor when caller did not bind -HeadroomFactor explicitly.
    if (-not $PSBoundParameters.ContainsKey('HeadroomFactor') -and
        $cfg.PSObject.Properties['headroom_factor'] -and
        $null -ne $cfg.headroom_factor -and
        [double]$cfg.headroom_factor -gt 0) {
        $HeadroomFactor = [double]$cfg.headroom_factor
    }

    $defaultTier = if ($cfg.PSObject.Properties['default_tier'] -and -not [string]::IsNullOrWhiteSpace([string]$cfg.default_tier)) {
        [string]$cfg.default_tier
    } else {
        'PureJson'
    }
    $thresholds = $cfg.thresholds

    $rawFindings = [math]::Max(0, $FindingCount)
    $rawEntities = [math]::Max(0, $EntityCount)
    $rawEdges = [math]::Max(0, $EdgeCount)

    $adjustedFindings = [int][math]::Ceiling($rawFindings * $HeadroomFactor)
    $adjustedEntities = [int][math]::Ceiling($rawEntities * $HeadroomFactor)
    $adjustedEdges = [int][math]::Ceiling($rawEdges * $HeadroomFactor)

    $findingTier = if ($adjustedFindings -ge [int]$thresholds.findings.pode) {
        'PodeViewer'
    } elseif ($adjustedFindings -ge [int]$thresholds.findings.sidecar) {
        'SidecarSqlite'
    } elseif ($adjustedFindings -ge [int]$thresholds.findings.embedded) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    $entityTier = if ($adjustedEntities -ge [int]$thresholds.entities.pode) {
        'PodeViewer'
    } elseif ($adjustedEntities -ge [int]$thresholds.entities.sidecar) {
        'SidecarSqlite'
    } elseif ($adjustedEntities -ge [int]$thresholds.entities.embedded) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    $edgeTier = if ($adjustedEdges -ge [int]$thresholds.edges.pode) {
        'PodeViewer'
    } elseif ($adjustedEdges -ge [int]$thresholds.edges.embedded) {
        'EmbeddedSqlite'
    } else {
        'PureJson'
    }

    # Apply manifest default_tier as a floor across all axes (manifest contract).
    $candidates = @($findingTier, $entityTier, $edgeTier, $defaultTier)
    $pickerTier = $candidates |
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
            throw "AZURE_ANALYZER_FORCE_ARCH must be one of (case-sensitive): $($script:ReportArchitectureTiers -join ', '). Received: $forcedTier."
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

    function Get-DependenciesForTier {
        param([string] $TierName)
        return @(
            $deps |
                Where-Object { $_ -and $_.PSObject.Properties['applicable_tiers'] -and (@($_.applicable_tiers) -contains $TierName) } |
                ForEach-Object { [string]$_.name }
        )
    }

    # Tiers backed only by placeholder verifiers report Success=$false (Status='placeholder')
    # so the picker / orchestrator can detect the gap and fall back to PureJson rather than
    # silently shipping an unrenderable tier. Real verifiers replace these in follow-up PRs.
    return [pscustomobject]@{
        PureJson = [pscustomobject]@{ Success = $true; Status = 'ready'; Errors = @(); Warnings = @(); Dependencies = @() }
        EmbeddedSqlite = [pscustomobject]@{ Success = $false; Status = 'placeholder'; Errors = @(); Warnings = @('placeholder verification stubs active'); Dependencies = @(Get-DependenciesForTier -TierName 'EmbeddedSqlite') }
        SidecarSqlite = [pscustomobject]@{ Success = $false; Status = 'placeholder'; Errors = @(); Warnings = @('placeholder verification stubs active'); Dependencies = @(Get-DependenciesForTier -TierName 'SidecarSqlite') }
        PodeViewer = [pscustomobject]@{ Success = $false; Status = 'placeholder'; Errors = @(); Warnings = @('placeholder verification stubs active'); Dependencies = @(Get-DependenciesForTier -TierName 'PodeViewer') }
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
        [object[]] $Features = @(),
        [object] $Policy = $null
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
        Policy              = if ($Policy) { $Policy } else { $null }
    }

    $json = $manifest | ConvertTo-Json -Depth 30
    # Atomic write: stage to a sibling temp file then move. Prevents truncated JSON on
    # interrupt and keeps any prior manifest readable until the new one is fully on disk.
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $stagingPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        Set-Content -Path $stagingPath -Value $json -Encoding UTF8 -NoNewline
        Move-Item -Path $stagingPath -Destination $Path -Force
    } catch {
        if (Test-Path $stagingPath) { Remove-Item -Path $stagingPath -Force -ErrorAction SilentlyContinue }
        throw
    }
    return $manifest
}
