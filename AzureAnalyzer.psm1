#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Analyzer PowerShell Module — Root module script.
.DESCRIPTION
    Loads all public functions from the modules/ directory and the root-level
    scripts (Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, New-MdReport.ps1).
    Private helper scripts are dot-sourced but not exported.
#>

Set-StrictMode -Version Latest

# Get the module root path
$ModuleRoot = Split-Path -Parent $PSScriptRoot

# Dot-source all tool wrapper modules from modules/ directory
# These are internal helpers and should not be exported directly
Get-ChildItem -Path (Join-Path $ModuleRoot 'modules') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Import public functions from root level
# These are exported in the manifest as FunctionsToExport
$publicFunctions = @(
    'Invoke-AzureAnalyzer',
    'New-HtmlReport',
    'New-MdReport'
)

foreach ($funcName in $publicFunctions) {
    $funcPath = Join-Path $ModuleRoot "$($funcName).ps1"
    if (Test-Path $funcPath) {
        . $funcPath
    }
}

# Ensure required modules are available
$requiredModules = @('Az.Accounts', 'Az.ResourceGraph')
foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -Name $moduleName -ErrorAction SilentlyContinue)) {
        try {
            Import-Module -Name $moduleName -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warning "Required module '$moduleName' not found. Install with: Install-Module $moduleName"
        }
    }
}

# Export public functions
Export-ModuleMember -Function $publicFunctions
