#Requires -Version 7.4
<#
.SYNOPSIS
    Per-tier post-render verification stubs for the report architecture.
.DESCRIPTION
    Phase 0 (#435) lands the verification entry-point contract. Each cmdlet
    accepts a -ReportRoot path plus an optional -Manifest object and returns
    a uniform PSCustomObject (Tier, Success, Status, Errors, Warnings,
    Checks, DurationMs, Timestamp). Real verification bodies (HtmlAgilityPack
    DOM checks, sqlite-wasm decode, Pode /api/health probe) ship with the
    matching tier PRs. The Phase 0 stubs return Status='ready' for PureJson
    when canonical artefacts exist and Status='placeholder' for richer tiers
    so the orchestrator can detect a missing renderer and fall back rather
    than silently shipping a blank report.
.NOTES
    All disk-bound output (warnings, error details) is routed through
    Remove-Credentials when that helper is available.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReportVerificationTiers = @('PureJson', 'EmbeddedSqlite', 'SidecarSqlite', 'PodeViewer')

function New-ReportVerificationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Tier,
        [Parameter(Mandatory)][bool] $Success,
        [Parameter(Mandatory)][string] $Status,
        [string[]] $Errors = @(),
        [string[]] $Warnings = @(),
        [object[]] $Checks = @(),
        [double] $DurationMs = 0.0
    )

    if ($Tier -notin $script:ReportVerificationTiers) {
        throw "Tier '$Tier' is not a recognised report architecture tier. Expected one of: $($script:ReportVerificationTiers -join ', ')."
    }

    $sanitize = {
        param([string] $s)
        if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
            return (Remove-Credentials $s)
        }
        return $s
    }

    return [pscustomobject]@{
        Tier       = $Tier
        Success    = [bool]$Success
        Status     = $Status
        Errors     = @($Errors | ForEach-Object { & $sanitize ([string]$_) })
        Warnings   = @($Warnings | ForEach-Object { & $sanitize ([string]$_) })
        Checks     = @($Checks)
        DurationMs = [double]$DurationMs
        Timestamp  = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-ReportRootArgument {
    [CmdletBinding()]
    param([string] $ReportRoot)

    $errors = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
        $errors.Add('ReportRoot is missing or empty.')
    } elseif (-not (Test-Path -LiteralPath $ReportRoot)) {
        $errors.Add("ReportRoot '$ReportRoot' does not exist on disk.")
    }
    return ,$errors.ToArray()
}

function Test-PureJsonOutput {
    <#
    .SYNOPSIS
        Verify the PureJson tier emitted a parseable HTML shell + sidecar JSON.
    .DESCRIPTION
        Phase 0 stub: confirms the report root exists and contains at least one
        of the canonical PureJson outputs (results.json, entities.json,
        report-manifest.json, or report.html). Real DOM validation via
        HtmlAgilityPack lands with Track F.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ReportRoot,
        [object] $Manifest
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $argErrors = Test-ReportRootArgument -ReportRoot $ReportRoot
    if ($argErrors.Count -gt 0) {
        $sw.Stop()
        return New-ReportVerificationResult -Tier 'PureJson' -Success $false -Status 'invalid-arguments' -Errors $argErrors -DurationMs $sw.Elapsed.TotalMilliseconds
    }

    $expected = @('results.json','entities.json','report-manifest.json','report.html')
    $present = @()
    foreach ($name in $expected) {
        if (Test-Path -LiteralPath (Join-Path $ReportRoot $name)) {
            $present += $name
        }
    }
    $sw.Stop()

    if ($present.Count -eq 0) {
        return New-ReportVerificationResult -Tier 'PureJson' -Success $false -Status 'missing-outputs' -Errors @("None of the canonical PureJson outputs were found under '$ReportRoot'.") -Checks @([pscustomobject]@{ Name='outputs'; Expected=$expected; Found=$present }) -DurationMs $sw.Elapsed.TotalMilliseconds
    }

    return New-ReportVerificationResult -Tier 'PureJson' -Success $true -Status 'ready' -Checks @([pscustomobject]@{ Name='outputs'; Expected=$expected; Found=$present }) -DurationMs $sw.Elapsed.TotalMilliseconds
}

function Test-EmbeddedSqliteOutput {
    <#
    .SYNOPSIS
        Verify the EmbeddedSqlite tier (base64-inline sqlite-wasm).
    .DESCRIPTION
        Phase 0 stub. Real implementation (Track viewer): decode the inline
        WASM blob, open the embedded DB, assert FTS5 index + entity tables.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ReportRoot,
        [object] $Manifest
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $argErrors = Test-ReportRootArgument -ReportRoot $ReportRoot
    $sw.Stop()
    if ($argErrors.Count -gt 0) {
        return New-ReportVerificationResult -Tier 'EmbeddedSqlite' -Success $false -Status 'invalid-arguments' -Errors $argErrors -DurationMs $sw.Elapsed.TotalMilliseconds
    }
    return New-ReportVerificationResult -Tier 'EmbeddedSqlite' -Success $false -Status 'placeholder' -Warnings @('EmbeddedSqlite verification stub: real WASM-decode body lands with the viewer PR.') -DurationMs $sw.Elapsed.TotalMilliseconds
}

function Test-SidecarSqliteOutput {
    <#
    .SYNOPSIS
        Verify the SidecarSqlite tier (separate .sqlite file beside HTML).
    .DESCRIPTION
        Phase 0 stub. Real implementation: open the sidecar DB, assert schema
        version, indexes, FTS5 virtual tables, foreign-key constraints.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ReportRoot,
        [object] $Manifest
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $argErrors = Test-ReportRootArgument -ReportRoot $ReportRoot
    $sw.Stop()
    if ($argErrors.Count -gt 0) {
        return New-ReportVerificationResult -Tier 'SidecarSqlite' -Success $false -Status 'invalid-arguments' -Errors $argErrors -DurationMs $sw.Elapsed.TotalMilliseconds
    }
    return New-ReportVerificationResult -Tier 'SidecarSqlite' -Success $false -Status 'placeholder' -Warnings @('SidecarSqlite verification stub: schema + index assertions land with the sidecar PR.') -DurationMs $sw.Elapsed.TotalMilliseconds
}

function Test-PodeViewerOutput {
    <#
    .SYNOPSIS
        Verify the PodeViewer tier (local Pode server boots and serves /api/health).
    .DESCRIPTION
        Phase 0 stub. Real implementation: launch viewer in dry-start mode,
        poll http://127.0.0.1:<port>/api/health for HTTP 200 within 30s,
        then shut it down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ReportRoot,
        [object] $Manifest
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $argErrors = Test-ReportRootArgument -ReportRoot $ReportRoot
    $sw.Stop()
    if ($argErrors.Count -gt 0) {
        return New-ReportVerificationResult -Tier 'PodeViewer' -Success $false -Status 'invalid-arguments' -Errors $argErrors -DurationMs $sw.Elapsed.TotalMilliseconds
    }
    return New-ReportVerificationResult -Tier 'PodeViewer' -Success $false -Status 'placeholder' -Warnings @('PodeViewer verification stub: /api/health probe lands with the viewer PR.') -DurationMs $sw.Elapsed.TotalMilliseconds
}

function Invoke-ReportVerification {
    <#
    .SYNOPSIS
        Dispatch verification to the per-tier stub for the selected architecture.
    .DESCRIPTION
        Convenience wrapper used by the orchestrator after a report is rendered.
        Looks up the matching Test-<Tier>Output cmdlet and forwards the call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Tier,
        [Parameter(Mandatory)][string] $ReportRoot,
        [object] $Manifest
    )

    if ($Tier -notin $script:ReportVerificationTiers) {
        throw "Tier '$Tier' is not a recognised report architecture tier. Expected one of: $($script:ReportVerificationTiers -join ', ')."
    }

    $cmdName = "Test-${Tier}Output"
    $cmd = Get-Command -Name $cmdName -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return New-ReportVerificationResult -Tier $Tier -Success $false -Status 'missing-verifier' -Errors @("Verifier '$cmdName' is not available in the current session.")
    }
    return & $cmd -ReportRoot $ReportRoot -Manifest $Manifest
}

function Get-ReportVerificationTiers {
    [CmdletBinding()]
    param ()
    return ,$script:ReportVerificationTiers
}
