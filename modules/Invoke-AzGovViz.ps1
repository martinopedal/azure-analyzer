#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for AzGovViz (Azure Governance Visualizer).
.DESCRIPTION
    Runs AzGovVizParallel.ps1 for a management group and returns a summary PSObject.
    If AzGovViz is not installed/found, writes a warning and returns empty result.
    Never throws.
.PARAMETER ManagementGroupId
    Management group ID to analyze.
.PARAMETER OutputPath
    Directory for AzGovViz output. Defaults to .\output\azgovviz.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ManagementGroupId,

    [string] $OutputPath = (Join-Path (Get-Location) 'output' 'azgovviz')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-AzGovViz {
    $candidates = @(
        (Join-Path (Get-Location) 'AzGovVizParallel.ps1'),
        (Join-Path (Get-Location) 'tools' 'AzGovViz' 'AzGovVizParallel.ps1'),
        (Join-Path $PSScriptRoot 'tools' 'AzGovViz' 'AzGovVizParallel.ps1'),
        (Join-Path $env:USERPROFILE 'AzGovViz' 'AzGovVizParallel.ps1'),
        (Join-Path $env:HOME 'AzGovViz' 'AzGovVizParallel.ps1')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

$azGovVizScript = Find-AzGovViz

if (-not $azGovVizScript) {
    Write-Warning "AzGovViz (AzGovVizParallel.ps1) not found. Skipping. Clone from https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting"
    return [PSCustomObject]@{
        Source   = 'azgovviz'
        Status   = 'Skipped'
        Message  = 'AzGovVizParallel.ps1 not found'
        Findings = @()
    }
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

try {
    Write-Verbose "Running AzGovViz for management group: $ManagementGroupId"
    pwsh -File $azGovVizScript `
        -ManagementGroupId $ManagementGroupId `
        -OutputPath $OutputPath `
        -AzureDevOpsWikiAsCode $false `
        -HierarchyTreeOnly $false `
        -ErrorAction Stop

    $summaryFiles = Get-ChildItem -Path $OutputPath -Filter '*Summary*.json' -Recurse -ErrorAction SilentlyContinue

    $findings = @()
    foreach ($file in $summaryFiles) {
        try {
            $data = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop
            $findings += $data
        } catch {
            Write-Warning "Could not parse AzGovViz output $($file.Name): $_"
        }
    }

    return [PSCustomObject]@{
        Source   = 'azgovviz'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
} catch {
    Write-Warning "AzGovViz run failed: $_"
    return [PSCustomObject]@{
        Source   = 'azgovviz'
        Status   = 'Failed'
        Message  = "$_"
        Findings = @()
    }
}
