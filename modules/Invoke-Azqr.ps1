#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Azure Quick Review (azqr) CLI.
.DESCRIPTION
    Scans an Azure subscription with azqr and returns findings as a PSObject.
    If azqr is not installed, writes a warning and returns an empty result.
    Never throws — designed for graceful degradation in the orchestrator.
.PARAMETER SubscriptionId
    The Azure subscription ID to scan.
.PARAMETER OutputPath
    Directory where azqr writes its output. Defaults to .\output\azqr.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [string] $OutputPath = (Join-Path (Get-Location) 'output' 'azqr')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AzqrInstalled {
    $null -ne (Get-Command azqr -ErrorAction SilentlyContinue)
}

if (-not (Test-AzqrInstalled)) {
    Write-Warning "azqr is not installed. Skipping Azqr scan. Install from https://azure.github.io/azqr"
    return [PSCustomObject]@{
        Source   = 'azqr'
        Findings = @()
    }
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

try {
    Write-Verbose "Running azqr scan for subscription $SubscriptionId"
    $null = azqr scan --subscription-id $SubscriptionId --output-dir $OutputPath 2>&1

    $jsonFiles = Get-ChildItem -Path $OutputPath -Filter '*.json' -ErrorAction SilentlyContinue
    $findings = @()

    foreach ($file in $jsonFiles) {
        try {
            $data = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop
            if ($data -is [array]) {
                $findings += $data
            } elseif ($null -ne $data) {
                $findings += $data
            }
        } catch {
            Write-Warning "Could not parse azqr output file $($file.Name): $_"
        }
    }

    return [PSCustomObject]@{
        Source   = 'azqr'
        Findings = $findings
    }
} catch {
    Write-Warning "azqr scan failed: $_"
    return [PSCustomObject]@{
        Source   = 'azqr'
        Findings = @()
    }
}
