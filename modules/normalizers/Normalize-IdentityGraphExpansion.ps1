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
    $edges = if ($ToolResult.PSObject.Properties['Edges'] -and $ToolResult.Edges) { @($ToolResult.Edges) } else { @() }

    foreach ($edge in $edges) {
        if (-not $edge) { continue }
        $source = if ($edge.PSObject.Properties['Source'] -and $edge.Source) { [string]$edge.Source } else { '' }
        $target = if ($edge.PSObject.Properties['Target'] -and $edge.Target) { [string]$edge.Target } else { '' }
        $relation = if ($edge.PSObject.Properties['Relation'] -and $edge.Relation) { [string]$edge.Relation } else { '' }

        $edgeRefs = @($source, $target, $(if ($relation) { "relation:$relation" } else { $null }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($edge.PSObject.Properties['EntityRefs']) {
            $edge.EntityRefs = @($edgeRefs)
        } else {
            $edge | Add-Member -NotePropertyName 'EntityRefs' -NotePropertyValue @($edgeRefs)
        }
    }

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

        if (-not ($f.PSObject.Properties['Frameworks']) -or -not $f.Frameworks -or @($f.Frameworks).Count -eq 0) {
            $frameworks = @(
                @{ Name = 'NIST 800-53'; Controls = @('AC-2', 'AC-6', 'IA-2', 'IA-5'); Pillars = @('Security') },
                @{ Name = 'CIS Controls v8'; Controls = @('5.4', '6.1', '6.8'); Pillars = @('Security') }
            )
            if ($f.PSObject.Properties['Frameworks']) { $f.Frameworks = @($frameworks) } else { $f | Add-Member -NotePropertyName 'Frameworks' -NotePropertyValue @($frameworks) }
        }

        if (-not ($f.PSObject.Properties['Pillar']) -or [string]::IsNullOrWhiteSpace([string]$f.Pillar)) {
            if ($f.PSObject.Properties['Pillar']) { $f.Pillar = 'Security' } else { $f | Add-Member -NotePropertyName 'Pillar' -NotePropertyValue 'Security' }
        }
        if (-not ($f.PSObject.Properties['Impact']) -or [string]::IsNullOrWhiteSpace([string]$f.Impact)) {
            $impact = switch ([string]$f.Severity) {
                'Critical' { 'High' }
                'High' { 'High' }
                'Medium' { 'Medium' }
                default { 'Low' }
            }
            if ($f.PSObject.Properties['Impact']) { $f.Impact = $impact } else { $f | Add-Member -NotePropertyName 'Impact' -NotePropertyValue $impact }
        }
        if (-not ($f.PSObject.Properties['Effort']) -or [string]::IsNullOrWhiteSpace([string]$f.Effort)) {
            $effort = switch ([string]$f.Severity) {
                'Critical' { 'High' }
                'High' { 'Medium' }
                'Medium' { 'Medium' }
                default { 'Low' }
            }
            if ($f.PSObject.Properties['Effort']) { $f.Effort = $effort } else { $f | Add-Member -NotePropertyName 'Effort' -NotePropertyValue $effort }
        }
        if (-not ($f.PSObject.Properties['DeepLinkUrl']) -or [string]::IsNullOrWhiteSpace([string]$f.DeepLinkUrl)) {
            $deepLink = 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Overview'
            if ($f.PSObject.Properties['DeepLinkUrl']) { $f.DeepLinkUrl = $deepLink } else { $f | Add-Member -NotePropertyName 'DeepLinkUrl' -NotePropertyValue $deepLink }
        }
        if (-not ($f.PSObject.Properties['MitreTactics']) -or -not $f.MitreTactics -or @($f.MitreTactics).Count -eq 0) {
            $tactics = @('TA0008', 'TA0004')
            if ($f.PSObject.Properties['MitreTactics']) { $f.MitreTactics = @($tactics) } else { $f | Add-Member -NotePropertyName 'MitreTactics' -NotePropertyValue @($tactics) }
        }
        if (-not ($f.PSObject.Properties['MitreTechniques']) -or -not $f.MitreTechniques -or @($f.MitreTechniques).Count -eq 0) {
            $techniques = @('T1078', 'T1098')
            if ($f.PSObject.Properties['MitreTechniques']) { $f.MitreTechniques = @($techniques) } else { $f | Add-Member -NotePropertyName 'MitreTechniques' -NotePropertyValue @($techniques) }
        }
        if (-not ($f.PSObject.Properties['ToolVersion']) -or [string]::IsNullOrWhiteSpace([string]$f.ToolVersion)) {
            $toolVersion = if ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) { [string]$ToolResult.ToolVersion } else { 'identity-graph-expansion@1.0' }
            if ($f.PSObject.Properties['ToolVersion']) { $f.ToolVersion = $toolVersion } else { $f | Add-Member -NotePropertyName 'ToolVersion' -NotePropertyValue $toolVersion }
        }

        $entityRefs = [System.Collections.Generic.List[string]]::new()
        if ($f.PSObject.Properties['EntityRefs'] -and $f.EntityRefs) {
            foreach ($existingRef in @($f.EntityRefs)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$existingRef)) {
                    $entityRefs.Add([string]$existingRef) | Out-Null
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($canonical)) {
            $entityRefs.Add($canonical) | Out-Null
        }
        foreach ($edge in $edges) {
            if (-not $edge) { continue }
            $source = if ($edge.PSObject.Properties['Source'] -and $edge.Source) { [string]$edge.Source } else { '' }
            $target = if ($edge.PSObject.Properties['Target'] -and $edge.Target) { [string]$edge.Target } else { '' }
            $relation = if ($edge.PSObject.Properties['Relation'] -and $edge.Relation) { [string]$edge.Relation } else { '' }
            if ($source -eq $canonical -or $target -eq $canonical) {
                if ($source) { $entityRefs.Add($source) | Out-Null }
                if ($target) { $entityRefs.Add($target) | Out-Null }
                if ($relation) { $entityRefs.Add("relation:$relation") | Out-Null }
            }
        }
        $dedupedRefs = @($entityRefs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($f.PSObject.Properties['EntityRefs']) { $f.EntityRefs = @($dedupedRefs) } else { $f | Add-Member -NotePropertyName 'EntityRefs' -NotePropertyValue @($dedupedRefs) }

        $normalized.Add($f)
    }

    return @($normalized)
}
