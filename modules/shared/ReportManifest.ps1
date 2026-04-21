#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        @($Features) |
            Where-Object {
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
