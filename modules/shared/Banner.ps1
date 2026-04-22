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

    # ASCII-only banner: 7-bit safe so it renders identically in cmd.exe,
    # PowerShell ISE, Windows Terminal, and pwsh on Linux/macOS.
    $lines = @(
        '    _                       _                _',
        '   / \   _____   _ _ __ ___( )    _ _   __ _| |_   _ _______ _ __',
        '  / _ \ |_  / | | | |__/ _ \_/   / _` | / _` | | | | |_  / _ \ |__|',
        ' / ___ \ / /| |_| | | |  __/    | (_| || (_| | | |_| |/ /  __/ |',
        '/_/   \_\___|\__,_|_|  \___|     \__,_| \__,_|_|\__, /___\___|_|',
        "                                                |___/  v$Version"
    )

    if ($Writer) {
        foreach ($line in $lines) { $Writer.WriteLine($line) }
        return
    }

    if ($useColor) {
        foreach ($line in $lines) {
            Write-Host $line -ForegroundColor Cyan
        }
    } else {
        foreach ($line in $lines) {
            Write-Host $line
        }
    }
}
