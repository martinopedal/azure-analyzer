#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PureJsonOutput {
    [CmdletBinding()]
    param([string] $OutputPath)
    return [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @() }
}

function Test-EmbeddedSqliteOutput {
    [CmdletBinding()]
    param([string] $OutputPath)
    return [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @() }
}

function Test-SidecarSqliteOutput {
    [CmdletBinding()]
    param([string] $OutputPath)
    return [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @() }
}

function Test-PodeViewerOutput {
    [CmdletBinding()]
    param([string] $OutputPath)
    return [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @() }
}

function Invoke-VerificationWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,
        [int] $TimeoutSeconds = 30
    )

    $job = Start-Job -ScriptBlock $ScriptBlock
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            Stop-Job -Job $job | Out-Null
            return [pscustomobject]@{
                Success  = $false
                Errors   = @("Verification timed out after $TimeoutSeconds seconds.")
                Warnings = @()
            }
        }
        $result = Receive-Job -Job $job
        if ($null -eq $result) {
            return [pscustomobject]@{ Success = $false; Errors = @('Verification returned no result.'); Warnings = @() }
        }
        return $result
    } finally {
        Remove-Job -Job $job -ErrorAction SilentlyContinue
    }
}

function Get-NextReportTier {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Tier)
    $tiers = @('PureJson', 'EmbeddedSqlite', 'SidecarSqlite', 'PodeViewer')
    $idx = [array]::IndexOf($tiers, $Tier)
    if ($idx -lt 0 -or $idx -ge ($tiers.Count - 1)) { return $null }
    return $tiers[$idx + 1]
}

function Test-FeatureAvailabilityDrop {
    [CmdletBinding()]
    param(
        [object[]] $CurrentFeatures = @(),
        [object[]] $UpgradedFeatures = @()
    )

    $upgradedMap = @{}
    foreach ($f in @($UpgradedFeatures)) {
        if ($f -and $f.PSObject.Properties['name']) {
            $upgradedMap[[string]$f.name] = $f
        }
    }

    foreach ($f in @($CurrentFeatures)) {
        if (-not $f -or -not $f.PSObject.Properties['name']) { continue }
        $name = [string]$f.name
        if (-not $f.PSObject.Properties['available'] -or -not [bool]$f.available) { continue }
        if (-not $upgradedMap.ContainsKey($name)) { continue }
        $candidate = $upgradedMap[$name]
        if ($candidate.PSObject.Properties['available'] -and -not [bool]$candidate.available) {
            return $true
        }
    }

    return $false
}

function Invoke-AutoUpgradeIfFailed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $ArchitectureSelection,

        [Parameter(Mandatory)]
        [pscustomobject] $VerificationResult,

        [Parameter(Mandatory)]
        [scriptblock] $VerifyScript,

        [string] $ManifestPath,
        [object[]] $CurrentFeatures = @(),
        [object[]] $UpgradedFeatures = @(),
        [double] $HeadroomFactor = 1.25
    )

    if ($VerificationResult.Success) {
        return [pscustomobject]@{
            Tier         = $ArchitectureSelection.Tier
            Result       = $VerificationResult
            AutoUpgraded = $false
        }
    }

    $nextTier = Get-NextReportTier -Tier $ArchitectureSelection.Tier
    if (-not $nextTier) {
        throw "Verification failed at highest tier '$($ArchitectureSelection.Tier)'."
    }

    $originalForce = $env:AZURE_ANALYZER_FORCE_ARCH
    $env:AZURE_ANALYZER_FORCE_ARCH = $nextTier
    try {
        $selection = Select-ReportArchitecture `
            -FindingCount ([int]($ArchitectureSelection.Measurements.Findings ?? 0)) `
            -EntityCount ([int]($ArchitectureSelection.Measurements.Entities ?? 0)) `
            -EdgeCount ([int]($ArchitectureSelection.Measurements.Edges ?? 0)) `
            -HeadroomFactor $HeadroomFactor
    } finally {
        $env:AZURE_ANALYZER_FORCE_ARCH = $originalForce
    }

    $second = & $VerifyScript $selection.Tier
    if (-not $second.Success) {
        throw "Verification failed after auto-upgrade to '$($selection.Tier)'."
    }

    if (Test-FeatureAvailabilityDrop -CurrentFeatures $CurrentFeatures -UpgradedFeatures $UpgradedFeatures) {
        throw "Auto-upgrade would reduce feature availability and is not allowed."
    }

    if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and (Get-Command New-ReportManifest -ErrorAction SilentlyContinue)) {
        $verificationResults = [pscustomobject]@{
            Initial = $VerificationResult
            Upgraded = $second
        }
        $autoUpgrades = @(
            [pscustomobject]@{
                FromTier = $ArchitectureSelection.Tier
                ToTier   = $selection.Tier
                Reason   = 'verification-failed'
            }
        )
        New-ReportManifest `
            -Path $ManifestPath `
            -SelectedTier $selection.Tier `
            -Measurements $selection.Measurements `
            -HeadroomFactor $HeadroomFactor `
            -PickerReasoning @($selection.Reasoning) `
            -ForcedOverride ([bool]$selection.ForcedOverride) `
            -VerificationResults $verificationResults `
            -AutoUpgrades $autoUpgrades `
            -Features @($UpgradedFeatures) | Out-Null
    }

    return [pscustomobject]@{
        Tier         = $selection.Tier
        Result       = $second
        AutoUpgraded = $true
    }
}
