#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Falco wrapper output.
.DESCRIPTION
    Converts v1 Falco findings to v2 FindingRows on AKS AzureResource entities.
    Falco priority mapping:
      - Critical -> Critical
      - Error    -> High
      - Warning  -> Medium
      - Notice   -> Low
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-Falco {
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

        try   { $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        $priority = if ($f.PSObject.Properties['Priority'] -and $f.Priority) { [string]$f.Priority } else { '' }
        $sev = switch -Regex ($priority) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)error$'    { 'High' }
            '^(?i)warning$'  { 'Medium' }
            '^(?i)notice$'   { 'Low' }
            default {
                if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Info' }
            }
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'falco' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title ([string]$f.Title) -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'KubernetesRuntimeThreatDetection' -Severity $sev `
            -Detail ([string]$f.Detail) -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg

        foreach ($extra in 'RuleName', 'Pod', 'Process', 'Priority') {
            if ($f.PSObject.Properties[$extra] -and $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue ([string]$f.$extra) -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
