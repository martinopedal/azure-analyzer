#Requires -Version 7.4
<#
.SYNOPSIS
    Azure Analyzer PowerShell Module - Root module script.
.DESCRIPTION
    Loads shared helper functions and root-level public entry scripts.
    The public commands are exposed via wrapper functions that invoke the
    scripts (Invoke-AzureAnalyzer.ps1, New-HtmlReport.ps1, New-MdReport.ps1).
    
    This is a local module for convenience; use after Import-Module ./AzureAnalyzer.psd1
    in the cloned repository.
#>

Set-StrictMode -Version Latest

# Get the module root path
$ModuleRoot = $PSScriptRoot

# Dot-source shared helper modules only
# Wrapper/normalizer/report scripts are invoked by the orchestrator and not loaded at import time
$sharedModulePath = Join-Path $ModuleRoot 'modules\shared'
Get-ChildItem -Path $sharedModulePath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

# Import public functions from root level
# These are exported in the manifest as FunctionsToExport
$publicFunctions = @(
    'Invoke-AzureAnalyzer',
    'New-HtmlReport',
    'New-MdReport'
)

function Invoke-ModuleScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ScriptPath,

        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Required script not found: $ScriptPath"
    }

    & $ScriptPath @Arguments
}

function Invoke-AzureAnalyzer {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    Invoke-ModuleScript -ScriptPath (Join-Path $ModuleRoot 'Invoke-AzureAnalyzer.ps1') @Arguments
}

function New-HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    Invoke-ModuleScript -ScriptPath (Join-Path $ModuleRoot 'New-HtmlReport.ps1') @Arguments
}

function New-MdReport {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Arguments
    )

    Invoke-ModuleScript -ScriptPath (Join-Path $ModuleRoot 'New-MdReport.ps1') @Arguments
}

# Warn if core required modules are missing
$coreRequired = @('Az.Accounts', 'Az.ResourceGraph')
foreach ($moduleName in $coreRequired) {
    if (-not (Get-Module -Name $moduleName -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Warning "Core module '$moduleName' not found. Install with: Install-Module $moduleName -Scope CurrentUser"
    }
}

# Export public functions
Export-ModuleMember -Function $publicFunctions

