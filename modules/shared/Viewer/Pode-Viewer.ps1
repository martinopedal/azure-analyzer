# modules/shared/Viewer/Pode-Viewer.ps1
#
# Scaffold-only stubs for Track V (#430). Foundation (#435) wires these to a real Pode
# runspace; this PR ships signatures + threat-model anchors so downstream PRs can land
# verticals incrementally without churning the public surface.
#
# Threat model: docs/design/viewer-threat-model.md (defenses D1..D12).
# Architecture:  docs/design/viewer-architecture.md
#
# DO NOT implement the Pode server here — that work lives in Foundation #435.

Set-StrictMode -Version Latest

function Start-AzureAnalyzerViewer {
    <#
    .SYNOPSIS
        Start the local Pode-backed findings viewer (Tier 4).
    .DESCRIPTION
        Binds 127.0.0.1 only (D1), random port 7000-7099 (D2), mints a session token (D7)
        and CSRF token (D6), writes .viewer-session.json with restrictive ACL (D10), and
        registers all middleware defenses before exposing any route.
    .PARAMETER ManifestPath
        Absolute path to report-manifest.json emitted by the orchestrator.
    .PARAMETER Port
        Optional explicit port. When omitted, a random free port in 7000-7099 is chosen.
    .PARAMETER SessionToken
        Optional explicit session token (GUID). When omitted, a fresh GUID is minted.
    .OUTPUTS
        PSCustomObject with Port, SessionToken, CsrfToken, SessionFilePath, Pid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter()] [int] $Port,
        [Parameter()] [string] $SessionToken
    )
    throw [System.NotImplementedException]::new('Start-AzureAnalyzerViewer: scaffold only — implementation lands in Foundation #435.')
}

function Stop-AzureAnalyzerViewer {
    <#
    .SYNOPSIS
        Stop the running viewer and tear down the session file.
    .DESCRIPTION
        Closes the Pode runspace, deletes .viewer-session.json, releases the port. Idempotent.
    #>
    [CmdletBinding()]
    param()
    throw [System.NotImplementedException]::new('Stop-AzureAnalyzerViewer: scaffold only — implementation lands in Foundation #435.')
}

function Test-ViewerHealth {
    <#
    .SYNOPSIS
        Probe /api/health on the running viewer.
    .OUTPUTS
        $true if /api/health returns 200 within the timeout, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $SessionToken,
        [Parameter()] [int] $TimeoutSeconds = 5
    )
    throw [System.NotImplementedException]::new('Test-ViewerHealth: scaffold only — implementation lands in Foundation #435.')
}

# ---------------------------------------------------------------------------
# Security middleware helpers (defense anchors).
# Each helper is its own function so the Pester suite can target it directly.
# ---------------------------------------------------------------------------

function Test-LoopbackBind {
    <#
    .SYNOPSIS
        D1: assert the listener is bound to 127.0.0.1 only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $Port)
    throw [System.NotImplementedException]::new('Test-LoopbackBind: scaffold only.')
}

function Test-HostHeader {
    <#
    .SYNOPSIS
        D3: validate inbound Host header equals 127.0.0.1:<port> or localhost:<port>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostHeader,
        [Parameter(Mandatory)] [int] $Port
    )
    throw [System.NotImplementedException]::new('Test-HostHeader: scaffold only.')
}

function Test-OriginHeader {
    <#
    .SYNOPSIS
        D4: reject any Origin header that is not the loopback origin for this launch.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [AllowNull()][AllowEmptyString()] [string] $OriginHeader,
        [Parameter(Mandatory)] [int] $Port
    )
    throw [System.NotImplementedException]::new('Test-OriginHeader: scaffold only.')
}

function Test-CsrfToken {
    <#
    .SYNOPSIS
        D6: constant-time compare the X-CSRF-Token header to the per-launch token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Provided,
        [Parameter(Mandatory)] [string] $Expected
    )
    throw [System.NotImplementedException]::new('Test-CsrfToken: scaffold only.')
}

function Test-EntityIdSafe {
    <#
    .SYNOPSIS
        D8: validate an entity-ID query parameter against the strict regex and length cap.
    .DESCRIPTION
        Accepts ^[a-zA-Z0-9:_\-\/\.]+$ up to 512 chars. Returns $true / $false. Never used
        for path construction by callers; this is input validation only.
    #>
    [CmdletBinding()]
    param([Parameter()] [AllowNull()][AllowEmptyString()] [string] $EntityId)
    throw [System.NotImplementedException]::new('Test-EntityIdSafe: scaffold only.')
}

Export-ModuleMember -Function @(
    'Start-AzureAnalyzerViewer',
    'Stop-AzureAnalyzerViewer',
    'Test-ViewerHealth',
    'Test-LoopbackBind',
    'Test-HostHeader',
    'Test-OriginHeader',
    'Test-CsrfToken',
    'Test-EntityIdSafe'
)
