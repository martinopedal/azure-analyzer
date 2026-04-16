#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for identity correlator findings.
.DESCRIPTION
    Passthrough normalizer -- the identity correlator already emits v3
    FindingRow objects via New-FindingRow, so this function validates and
    returns them as-is.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"

function Normalize-IdentityCorrelation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in $ToolResult.Findings) {
        if (-not $finding) { continue }
        $normalized.Add($finding)
    }

    return @($normalized)
}
