#Requires -Version 7.0
<#
.SYNOPSIS
    Canonical helpers for mocking tool-presence checks in wrapper tests.

.DESCRIPTION
    Category 12 of the Sentinel consistency sweep (#472). Tests that exercise
    wrapper paths which call `Get-Command <cli>` or `Get-Module -ListAvailable`
    should use these helpers to normalize how tool presence is faked, keeping
    Pester transcripts free of noisy "<tool> is not installed" warnings while
    still allowing tests that intentionally assert on soft-fail behaviour to
    exercise those code paths.

    Preferred order for tests that don't care about the soft-fail warning:
      1. Set-ToolPresenceMock -Tools 'trivy','terraform' -Present:$true
         (wrapper believes the tool is installed; warning path not reached)
      2. $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'
         (already set by tests/_Bootstrap.Tests.ps1; belt-and-suspenders)

    For tests that DO assert on soft-fail behaviour, use:
      Set-ToolPresenceMock -Tools 'trivy' -Present:$false
      ...then Should -Invoke Write-MissingToolNotice -ParameterFilter { ... }

    NOTE: the `-Present` switch is intentionally set via -Present:$true /
    -Present:$false rather than positionally because PowerShell switch
    parameters default to $true; callers should be explicit about intent.

.EXAMPLE
    # Inside a Pester BeforeAll:
    . (Join-Path $PSScriptRoot '..' '_helpers' 'Mock-ToolPresence.ps1')
    Set-ToolPresenceMock -Tools 'trivy' -Present:$true

.EXAMPLE
    # Exercise the missing-tool soft-fail path explicitly:
    Set-ToolPresenceMock -Tools 'trivy' -Present:$false
    $result = & $wrapper
    $result.Status | Should -Be 'Skipped'
#>

Set-StrictMode -Version Latest

function Set-ToolPresenceMock {
    <#
    .SYNOPSIS
        Mock Get-Command so a named set of CLI tools appears present or absent.
    .PARAMETER Tools
        CLI tool names (as used with Get-Command), e.g. 'trivy', 'terraform'.
    .PARAMETER Present
        When $true (default), Get-Command returns a stub command object.
        When $false, Get-Command returns $null to simulate "not installed".
    .PARAMETER ModuleScope
        Optional Pester module scope name to target the mock to a specific
        module (e.g. when the wrapper is loaded as a module).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string[]] $Tools,
        [bool] $Present = $true,
        [string] $ModuleScope
    )

    $mockParams = @{
        CommandName     = 'Get-Command'
        ParameterFilter = { $Name -in $Tools }.GetNewClosure()
        MockWith        = if ($Present) {
            { [PSCustomObject]@{ Name = $Name; CommandType = 'Application'; Source = "/usr/local/bin/$Name" } }.GetNewClosure()
        } else {
            { $null }
        }
    }
    if ($ModuleScope) { $mockParams.ModuleName = $ModuleScope }

    Mock @mockParams
}

function Set-ModulePresenceMock {
    <#
    .SYNOPSIS
        Mock Get-Module -ListAvailable so named PowerShell modules appear
        present or absent. Complements Set-ToolPresenceMock for wrappers
        whose soft-fail path checks modules (Maester, WARA, Az.ResourceGraph,
        etc.) instead of CLIs.
    .PARAMETER Modules
        Module names.
    .PARAMETER Present
        When $true, returns a stub module info object. When $false, returns
        an empty collection.
    .PARAMETER Version
        Optional version string for the stub module info.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string[]] $Modules,
        [bool] $Present = $true,
        [string] $Version = '1.0.0'
    )

    $mockParams = @{
        CommandName     = 'Get-Module'
        ParameterFilter = { $Name -in $Modules -and $ListAvailable }.GetNewClosure()
        MockWith        = if ($Present) {
            { [PSCustomObject]@{ Name = $Name; Version = [Version]$Version } }.GetNewClosure()
        } else {
            { @() }
        }
    }

    Mock @mockParams
}
