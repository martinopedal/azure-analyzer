#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Regression guard for issue #473 (and the broader bug class):
#
#   When Invoke-AzureAnalyzer.ps1 is executed via the AzureAnalyzer.psm1
#   wrapper (i.e. through the public Invoke-AzureAnalyzer module function),
#   any scriptblock that the orchestrator hands to a callee living in a
#   different session state must NOT depend on functions that are only
#   defined at the orchestrator's script scope. The original bug was a
#   `ShouldRunTool` reference inside a scriptblock dispatched from
#   Install-PrerequisitesFromManifest, which crashed with a
#   CommandNotFoundException because the predicate function was invisible
#   from the installer's session state.
#
#   This test imports the public module and drives the orchestrator far
#   enough to execute the prerequisite installer pass, asserting that:
#     - the wrapper function is exported
#     - invocation does NOT raise a CommandNotFoundException for any
#       script-scope helper (ShouldRunTool, etc.)
#     - any failure that does occur is descriptive, not a NameError
#
#   Cosmetic / environmental failures (missing tools, missing Az context,
#   fake subscription rejection) are acceptable; the test specifically
#   guards against the fail-with-NameError class.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Psd1 = Join-Path $script:RepoRoot 'AzureAnalyzer.psd1'
}

Describe 'Entry-point smoke (psm1 wrapper) - regression guard for #473' {

    It 'AzureAnalyzer.psm1 imports without errors and exports public functions' {
        Get-Module AzureAnalyzer -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
        { Import-Module $script:Psd1 -Force -ErrorAction Stop } | Should -Not -Throw

        $exported = (Get-Module AzureAnalyzer).ExportedFunctions.Keys
        $exported | Should -Contain 'Invoke-AzureAnalyzer'
        $exported | Should -Contain 'New-HtmlReport'
        $exported | Should -Contain 'New-MdReport'
    }

    It 'Invoke-AzureAnalyzer called via psm1 wrapper does not crash with CommandNotFoundException for script-scope helpers' {
        Get-Module AzureAnalyzer -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $script:Psd1 -Force

        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("aa-smoke-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpOut -Force

        $caught = $null
        try {
            # Exercise the prerequisite-install dispatch path by NOT passing
            # -SkipPrereqCheck. We pick a tool that is unlikely to be
            # installed (azqr) so the orchestrator exits quickly via the
            # skipped path rather than attempting real Azure calls.
            # -NonInteractive prevents PowerShell from prompting for missing
            # mandatory parameters in CI.
            $null = Invoke-AzureAnalyzer `
                -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -IncludeTools 'azqr' `
                -OutputPath $tmpOut `
                -NonInteractive `
                -ErrorAction Stop 2>&1
        } catch {
            $caught = $_
        } finally {
            if (Test-Path $tmpOut) {
                Remove-Item $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        if ($null -ne $caught) {
            $msg = [string]$caught.Exception.Message
            $type = $caught.Exception.GetType().FullName

            $type | Should -Not -Be 'System.Management.Automation.CommandNotFoundException' -Because (
                "Wrapper-dispatched scriptblocks must capture variables, " +
                "not reference script-scope functions. Failure indicates a " +
                "regression of #473. Message was: $msg"
            )

            $msg | Should -Not -Match '\bShouldRunTool\b' -Because (
                "ShouldRunTool was the original casualty in #473. If it " +
                "appears in any error message from the wrapper path, the " +
                "fix has regressed."
            )

            $msg | Should -Not -Match 'is not recognized as a name of a cmdlet, function, script file, or executable program' -Because (
                "A NameError-class crash in wrapper-mode means a closure " +
                "leaked a function reference across session-state boundaries. " +
                "Capture it as a variable instead. Original error: $msg"
            )
        }
    }
}
