#Requires -Version 7.0
<#
.SYNOPSIS
    Pester auto-bootstrap. Loaded first (underscore prefix sorts before alpha).

.DESCRIPTION
    Ensures AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS is set for the
    lifetime of the Pester run so that wrapper code paths that land on
    Write-MissingToolNotice (modules/shared/MissingTool.ps1) are silenced.

    Local developers running `Invoke-Pester -Path ./tests` pick this up
    automatically without having to dot-source tests/_helpers/setup.ps1.
    CI already dot-sources setup.ps1; this is a belt-and-suspenders safety
    net that also covers subset invocations like
    `Invoke-Pester -Path ./tests/wrappers`.

    Category 12 of the Sentinel consistency sweep (#472).
#>

$helperSetup = Join-Path $PSScriptRoot '_helpers' 'setup.ps1'
if (Test-Path $helperSetup) { . $helperSetup }

Describe 'Test suite bootstrap' {
    It 'exports AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS=1 for the run' {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS | Should -Be '1'
    }
}
