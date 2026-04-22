#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helper for emitting "<tool> is not installed" notices.
.DESCRIPTION
    Centralizes the policy for how a tool wrapper should react when its
    underlying CLI / module is missing.

    Policy:
      - If the wrapper was launched standalone (no orchestrator env var
        present) the user explicitly invoked it, so we keep the loud
        Write-Warning.
      - If the orchestrator launched the wrapper AND the user explicitly
        named the tool via -IncludeTools, keep the loud Write-Warning so
        the requested tool's absence is actionable.
      - Otherwise (default scan with no filter, tool happens to be
        missing), downgrade to Write-Verbose so the launch surface stays
        quiet. Issue #472.

    The orchestrator sets two environment variables for the lifetime of
    a run:
      - AZURE_ANALYZER_ORCHESTRATED       = '1'
      - AZURE_ANALYZER_EXPLICIT_TOOLS     = comma-separated tool names
        from -IncludeTools (empty string when no filter was passed)

    Both are cleaned up at the end of the orchestrator script.
#>

function Test-ToolExplicitlyRequested {
    param ([Parameter(Mandatory)][string] $Tool)

    if (-not $env:AZURE_ANALYZER_ORCHESTRATED) {
        return $true
    }
    $explicit = $env:AZURE_ANALYZER_EXPLICIT_TOOLS
    if ([string]::IsNullOrWhiteSpace($explicit)) {
        return $false
    }
    $names = $explicit.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return ($Tool -in $names)
}

function Write-MissingToolNotice {
    <#
    .SYNOPSIS
        Emit a "<tool> is not installed" notice at the appropriate volume.
    .PARAMETER Tool
        The tool name as registered in tool-manifest.json (e.g. 'trivy').
    .PARAMETER Message
        The full human-readable warning text including remediation hints.
    .PARAMETER ExplicitlyRequested
        Optional override. If omitted, the helper consults
        AZURE_ANALYZER_ORCHESTRATED / AZURE_ANALYZER_EXPLICIT_TOOLS.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $Tool,
        [Parameter(Mandatory)][string] $Message,
        [object] $ExplicitlyRequested
    )

    $explicit = if ($PSBoundParameters.ContainsKey('ExplicitlyRequested')) {
        [bool]$ExplicitlyRequested
    } else {
        Test-ToolExplicitlyRequested -Tool $Tool
    }

    if ($explicit) {
        Write-Warning $Message
    } else {
        Write-Verbose "[missing-tool] $Message"
    }
}
