#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for kubescape wrapper output.
.DESCRIPTION
    Converts v1 kubescape wrapper output to v2 FindingRows.
    Each non-passing control becomes a FindingRow on the AKS cluster's canonical ARM ID
    (EntityType=AzureResource, Platform=Azure) so kubescape findings fold onto the same
    entity as azqr/PSRule/Defender recommendations for that cluster.
    ControlId (e.g. C-0001, CIS-5.1.3) surfaces on Controls[] for framework mapping.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-Kubescape {
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
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg    = $Matches[1] }

        try   { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        $sevRaw = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Medium' }
        $sev = switch -Regex ($sevRaw) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            '^(?i)info'      { 'Info' }
            default          { 'Medium' }
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'kubescape' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title ([string]$f.Title) -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'KubernetesPosture' -Severity $sev `
            -Detail ([string]$f.Detail) -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg

        if ($f.PSObject.Properties['ControlId'] -and $f.ControlId) {
            $row | Add-Member -NotePropertyName ControlId -NotePropertyValue ([string]$f.ControlId) -Force
        }

        # Skip null rows (validation failed)

        if ($null -ne $row) {

            $normalized.Add($row)

        }
    }

    return @($normalized)
}
