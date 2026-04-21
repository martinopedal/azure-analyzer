#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-flight required-input collection (scaffold).

.DESCRIPTION
    Stub module for the pre-flight layer that resolves every mandatory wrapper
    input before any tool is invoked. See docs/design/preflight-inputs.md for
    the full design. Function bodies intentionally throw "Not implemented in
    foundation"; the working implementation lands once Foundation PR #435 has
    merged and orchestrator wiring is unblocked.

    Issue: #426
    Epic:  #427 (Phase 1 critical path)
#>

Set-StrictMode -Version Latest

# Maps to design doc section 2 (Manifest schema extension) and section 4
# (Mandatory-input catalog). Walks the supplied tool list, parses each tool's
# required_inputs array from tool-manifest.json, and returns the deduplicated
# union of input descriptors for the orchestrator to resolve once.
function Get-RequiredInputsFromManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $ToolList
    )
    throw "Not implemented in foundation"
}

# Maps to design doc section 3 (Resolution order: CLI > env > prompt > fail)
# and section 6 (Non-interactive detection). Walks each requirement, applies
# the resolution chain, validates, and returns a hashtable of resolved values.
# In non-interactive mode skips the prompt step and aggregates all unresolved
# inputs into a single fail-fast error (no per-input prompting in CI).
function Resolve-PreFlightInputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Requirements,

        [Parameter(Mandatory = $false)]
        [hashtable] $CliArgs = @{},

        [Parameter(Mandatory = $false)]
        [switch] $Interactive
    )
    throw "Not implemented in foundation"
}

# Maps to design doc section 6 (Non-interactive detection). Returns $true when
# the session cannot prompt the user (stdin redirected, -NonInteractive flag,
# CI env var set, or UserInteractive false).
function Test-NonInteractiveSession {
    [CmdletBinding()]
    param()
    throw "Not implemented in foundation"
}

Export-ModuleMember -Function @(
    'Get-RequiredInputsFromManifest',
    'Resolve-PreFlightInputs',
    'Test-NonInteractiveSession'
) -ErrorAction SilentlyContinue
