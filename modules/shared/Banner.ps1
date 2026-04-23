#Requires -Version 7.4

# AzureAnalyzer startup banner.
# Write-Host is intentional: this is a UI/presentation surface for interactive
# console runs, not data output. The function is a no-op when -NoBanner or
# -Quiet is passed, or when $env:AZUREANALYZER_NO_BANNER is set.
# Color codes are emitted via -ForegroundColor only and are skipped entirely
# when $env:NO_COLOR is set (per https://no-color.org/).

function Get-AzureAnalyzerVersion {
    [CmdletBinding()]
    param (
        [string] $ManifestPath = (Join-Path $PSScriptRoot '..' '..' 'AzureAnalyzer.psd1')
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return 'unknown'
    }

    try {
        $data = Import-PowerShellDataFile -LiteralPath $ManifestPath -ErrorAction Stop
        if ($data.ModuleVersion) { return [string]$data.ModuleVersion }
    } catch {
        # Fall through to regex fallback if the manifest cannot be parsed.
    }

    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop
        $match = [regex]::Match($raw, "ModuleVersion\s*=\s*'([^']+)'")
        if ($match.Success) { return $match.Groups[1].Value }
    } catch {
        # Ignore: caller will get 'unknown'.
    }

    return 'unknown'
}

function Write-AzureAnalyzerBanner {
    [CmdletBinding()]
    param (
        [switch] $NoBanner,
        [switch] $Quiet,
        [string] $Version,
        [System.IO.TextWriter] $Writer
    )

    if ($NoBanner) { return }
    if ($Quiet) { return }
    if ($env:AZUREANALYZER_NO_BANNER) { return }

    if (-not $Version) { $Version = Get-AzureAnalyzerVersion }

    $useColor = -not $env:NO_COLOR

    # Two-block ASCII banner (Standard figlet font, 7-bit safe).
    # AZURE rendered in Cyan, ANALYZER in Yellow for readability.
    $azureLines = @(
        '    _     ______   _ ____  _____'
        '   / \   |__  / | | |  _ \| ____|'
        '  / _ \    / /| | | | |_) |  _|'
        ' / ___ \  / /_| |_| |  _ <| |___'
        '/_/   \_\/____|\___|_| \_\_____|'
    )

    $analyzerLines = @(
        '    _    _   _    _    _  __   ____________ ____'
        '   / \  | \ | |  / \  | | \ \ / /__  / ____|  _ \'
        '  / _ \ |  \| | / _ \ | |  \ V /  / /|  _| | |_) |'
        ' / ___ \| |\  |/ ___ \| |___| |  / /_| |___|  _ <'
        '/_/   \_\_| \_/_/   \_\_____|_| /____|_____|_| \_\'
    )

    $versionLine = "                                          v$Version"

    if ($Writer) {
        foreach ($line in $azureLines) { $Writer.WriteLine($line) }
        foreach ($line in $analyzerLines) { $Writer.WriteLine($line) }
        $Writer.WriteLine($versionLine)
        return
    }

    if ($useColor) {
        foreach ($line in $azureLines) {
            Write-Host $line -ForegroundColor Cyan
        }
        foreach ($line in $analyzerLines) {
            Write-Host $line -ForegroundColor Yellow
        }
        Write-Host $versionLine -ForegroundColor DarkGray
    } else {
        foreach ($line in $azureLines) { Write-Host $line }
        foreach ($line in $analyzerLines) { Write-Host $line }
        Write-Host $versionLine
    }
}
