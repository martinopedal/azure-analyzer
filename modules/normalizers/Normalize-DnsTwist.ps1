#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for dnstwist (typosquat / homoglyph) findings.
.DESCRIPTION
    Converts the v1 wrapper envelope from Invoke-DnsTwist.ps1 into v2.2
    FindingRow objects via New-FindingRow.

    Each finding maps to EntityType=ExternalAsset / Platform=External by
    default; if the orchestrator passes -EntityIndex (built from the
    current EntityStore via Get-EasmEntityIndex), the normalizer routes
    the finding to the matching AzureResource when one exists.

    Domain=ExternalAttackSurface, Pillar=Exposure.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"
. "$PSScriptRoot\..\shared\EasmCorrelator.ps1"

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    if (-not $Obj.PSObject.Properties[$Name]) { return $Default }
    $v = $Obj.PSObject.Properties[$Name].Value
    if ($null -eq $v) { return $Default }
    return $v
}

function Normalize-DnsTwist {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult,

        # Optional: pre-built entity lookup index from
        # Get-EasmEntityIndex. When supplied, findings whose permutation
        # matches an existing AzureResource hostname are anchored there.
        # When omitted, every finding is treated as ExternalAsset.
        [hashtable] $EntityIndex
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $useIndex = $null -ne $EntityIndex
    $toolVersion = [string](Get-PropertyValue -Obj $ToolResult -Name 'ToolVersion' -Default '')

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($f in $ToolResult.Findings) {
        $findingId  = [string](Get-PropertyValue -Obj $f -Name 'Id'       -Default ([guid]::NewGuid().ToString()))
        $title      = [string](Get-PropertyValue -Obj $f -Name 'Title'    -Default 'Possible typosquat')
        $category   = [string](Get-PropertyValue -Obj $f -Name 'Category' -Default 'External Attack Surface')
        $detail     = [string](Get-PropertyValue -Obj $f -Name 'Detail'   -Default '')
        $remed      = [string](Get-PropertyValue -Obj $f -Name 'Remediation' -Default '')
        $resourceId = [string](Get-PropertyValue -Obj $f -Name 'ResourceId'  -Default '')
        $deepLink   = [string](Get-PropertyValue -Obj $f -Name 'DeepLinkUrl' -Default '')
        $ruleId     = [string](Get-PropertyValue -Obj $f -Name 'RuleId'      -Default '')
        $impact     = [string](Get-PropertyValue -Obj $f -Name 'Impact'      -Default 'Medium')
        $effort     = [string](Get-PropertyValue -Obj $f -Name 'Effort'      -Default 'Medium')
        $pillar     = [string](Get-PropertyValue -Obj $f -Name 'Pillar'      -Default 'Exposure')
        $perm       = [string](Get-PropertyValue -Obj $f -Name 'Permutation' -Default $resourceId)
        $seedDomain = [string](Get-PropertyValue -Obj $f -Name 'SeedDomain'  -Default '')

        $rawSev = [string](Get-PropertyValue -Obj $f -Name 'Severity' -Default 'Medium')
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'        { 'Critical' }
            'high'            { 'High' }
            'medium|moderate' { 'Medium' }
            'low'             { 'Low' }
            'info'            { 'Info' }
            default           { 'Medium' }
        }

        # Entity resolution. Try to anchor the typosquat permutation to
        # an Azure-owned resource (rare; would mean we own a homoglyph
        # variant of our own brand and exposed it). Far more commonly,
        # the permutation is registered by a third party and falls
        # through to ExternalAsset.
        $entityRef = if ($useIndex -and $perm) {
            Resolve-EasmEntity -Index $EntityIndex -HostName $perm
        } else {
            [PSCustomObject]@{
                EntityId   = if ($perm) { "host:$($perm.ToLowerInvariant())" } else { 'external:unknown' }
                EntityType = 'ExternalAsset'
                Platform   = 'External'
                Confidence = 'Unconfirmed'
                MatchedOn  = 'none'
            }
        }

        # Canonicalize the resolved EntityId so we don't leak casing /
        # trailing-dot variants into the entity store. New-FindingRow
        # itself does not canonicalize, so we must do it here.
        try {
            $canon = ConvertTo-CanonicalEntityId -RawId $entityRef.EntityId -EntityType $entityRef.EntityType
            $entityRef = [PSCustomObject]@{
                EntityId   = $canon.CanonicalId
                EntityType = $canon.EntityType
                Platform   = $canon.Platform
                Confidence = $entityRef.Confidence
                MatchedOn  = $entityRef.MatchedOn
            }
        } catch {
            # If canonicalization rejects the ID (e.g. malformed AzureResource
            # ARM ID from a misconfigured index), fall back to ExternalAsset
            # rather than dropping the finding.
            $fallbackId = if ($perm) { "host:$($perm.ToLowerInvariant().TrimEnd('.'))" } else { 'external:unknown' }
            $entityRef = [PSCustomObject]@{
                EntityId   = $fallbackId
                EntityType = 'ExternalAsset'
                Platform   = 'External'
                Confidence = 'Unconfirmed'
                MatchedOn  = 'fallback'
            }
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'dnstwist' `
            -EntityId $entityRef.EntityId `
            -EntityType $entityRef.EntityType `
            -Platform $entityRef.Platform `
            -Title $title `
            -Compliant $false `
            -ProvenanceRunId $runId `
            -Category $category `
            -Severity $severity `
            -Detail $detail `
            -Remediation $remed `
            -ResourceId $resourceId `
            -RuleId $ruleId `
            -Pillar $pillar `
            -Impact $impact `
            -Effort $effort `
            -DeepLinkUrl $deepLink `
            -Confidence $entityRef.Confidence `
            -BaselineTags @("dnstwist:fuzzer:$([string](Get-PropertyValue -Obj $f -Name 'Fuzzer' -Default ''))", "dnstwist:seed:$seedDomain") `
            -ToolVersion $toolVersion

        if ($null -ne $row) { $rows.Add($row) | Out-Null }
    }

    return @($rows)
}
