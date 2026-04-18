#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Microsoft Sentinel incidents wrapper output.
.DESCRIPTION
    Converts v1 sentinel-incidents wrapper output to v2 FindingRows.
    - Each active incident maps to EntityType=AzureResource (workspace ARM resource),
      keyed to the Log Analytics workspace hosting Sentinel.
    - Severity is mapped from Sentinel's native values (High/Medium/Low/Informational).
    - All incidents are Compliant=false (active, unresolved incidents).
    - Extra fields (IncidentNumber, IncidentStatus, AlertCount, Classification,
      IncidentUrl, ProviderName) are attached via Add-Member.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-SentinelIncidents {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($f in $ToolResult.Findings) {
        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if (-not $rawId) { continue }

        $subId = ''
        $rg    = ''
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        # Sentinel incidents are workspace-scoped; entity is the workspace ARM resource
        $entityType = 'AzureResource'
        try   { $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        # Map Sentinel severity to schema casing (Critical/High/Medium/Low/Info)
        $sevRaw = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Medium' }
        $sev = switch -Regex ($sevRaw) {
            '^(?i)critical$'      { 'Critical' }
            '^(?i)high$'          { 'High' }
            '^(?i)medium$'        { 'Medium' }
            '^(?i)low$'           { 'Low' }
            '^(?i)info.*'         { 'Info' }
            default               { 'Medium' }
        }

        $compliant = $false
        if ($f.PSObject.Properties['Compliant']) { $compliant = [bool]$f.Compliant }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }

        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'sentinel-incidents' -EntityId $canonicalId -EntityType $entityType `
            -Title ([string]$f.Title) -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'ThreatDetection' -Severity $sev `
            -Detail ([string]$f.Detail) `
            -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg

        # Attach Sentinel-specific extras (out-of-schema)
        foreach ($extra in 'IncidentNumber', 'IncidentStatus', 'AlertCount', 'Classification', 'IncidentUrl', 'ProviderName', 'CreatedTime', 'LastModifiedTime') {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
