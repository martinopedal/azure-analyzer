#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for identity-graph-expansion results.
.DESCRIPTION
    The wrapper already returns v2 FindingRow objects (built via New-FindingRow),
    so the normalizer is largely a pass-through. Its responsibility is to:
      1. Filter out malformed findings.
      2. Re-canonicalise the EntityId defensively.
      3. Surface edge counts on the result envelope so the orchestrator can log them.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-IdentityGraphExpansion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if (-not $ToolResult -or $ToolResult.Status -ne 'Success' -or -not $ToolResult.PSObject.Properties['Findings']) {
        return @()
    }

    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($f in @($ToolResult.Findings)) {
        if (-not $f) { continue }
        # Findings are already v2; defensively re-canonicalise the EntityId.
        $entityType = if ($f.PSObject.Properties['EntityType'] -and $f.EntityType) { [string]$f.EntityType } else { 'User' }
        $rawEntityId = if ($f.PSObject.Properties['EntityId'] -and $f.EntityId) { [string]$f.EntityId } else { '' }
        $canonical = $rawEntityId
        if ($rawEntityId) {
            try {
                $canonical = (ConvertTo-CanonicalEntityId -RawId $rawEntityId -EntityType $entityType).CanonicalId
            } catch {
                $canonical = $rawEntityId.ToLowerInvariant()
            }
        }
        if ($f.PSObject.Properties['EntityId']) { $f.EntityId = $canonical }
        # Severity must be one of the five enum values; coerce anything unknown to Info.
        if ($f.PSObject.Properties['Severity']) {
            $rawSeverity = [string]$f.Severity
            switch ($rawSeverity.ToLowerInvariant()) {
                'critical' { $f.Severity = 'Critical' }
                'high'     { $f.Severity = 'High' }
                'medium'   { $f.Severity = 'Medium' }
                'low'      { $f.Severity = 'Low' }
                'info'     { $f.Severity = 'Info' }
                default    {
                    # Issue #187 / F4: log so wrapper regressions are visible
                    # instead of silently downgraded.
                    $fid = if ($f.PSObject.Properties['Id']) { [string]$f.Id } else { '<no-id>' }
                    Write-Warning "identity-graph-expansion normalizer: unknown severity '$rawSeverity' coerced to 'Info' for finding $fid"
                    $f.Severity = 'Info'
                }
            }
        }
        $normalized.Add($f)
    }

    return @($normalized)
}
