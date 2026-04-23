<#
.SYNOPSIS
    LiveTool tier helper for wrapper tests.

.DESCRIPTION
    Provides a BeforeDiscovery block to skip tests when the live tool is not installed
    and the LIVE_TOOL_TESTS environment variable is not set.

    Usage in a Pester wrapper test file:
        . (Join-Path $PSScriptRoot '_LiveTool.Helper.ps1')
        New-LiveToolSkipFilter -ToolName 'trivy'

    This will skip all tests in the file unless:
    - The tool (trivy) is installed on the system, OR
    - The LIVE_TOOL_TESTS=1 environment variable is set

.EXAMPLE
    # In tests/wrappers/Invoke-Trivy.Tests.ps1
    . (Join-Path $PSScriptRoot '_LiveTool.Helper.ps1')
    New-LiveToolSkipFilter -ToolName 'trivy'

    Describe 'Invoke-Trivy' {
        It 'runs successfully' {
            # This test is skipped unless trivy is installed or LIVE_TOOL_TESTS=1
        }
    }
#>

function New-LiveToolSkipFilter {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $ToolName
    )

    BeforeDiscovery {
        # Check if LIVE_TOOL_TESTS env var is set
        $forceLiveTests = [System.Environment]::GetEnvironmentVariable('LIVE_TOOL_TESTS') -eq '1'

        # Check if tool is installed (simple which-like check)
        $toolInstalled = $null -ne (Get-Command $ToolName -ErrorAction SilentlyContinue)

        # Skip all tests if tool is not installed and LIVE_TOOL_TESTS is not set
        if (-not $toolInstalled -and -not $forceLiveTests) {
            $PesterPreference.Skip.Skip = $true
        }
    }
}
