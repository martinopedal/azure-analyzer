#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Azure Quick Review (azqr) findings.
.DESCRIPTION
    Converts raw azqr wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=AzureResource.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = '')
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Normalize-Azqr {
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

    foreach ($finding in $ToolResult.Findings) {
        $rawId = Get-PropertyValue $finding 'ResourceId' (Get-PropertyValue $finding 'Id' '')
        $subId = ''
        $rg = ''
        $canonicalId = ''
        $findingId = Get-PropertyValue $finding 'Id' ([guid]::NewGuid().ToString())

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalMeta = ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource'
                $canonicalId = $canonicalMeta.CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '(?i)/subscriptions/([^/]+)') { $subId = $Matches[1].ToLowerInvariant() }
            if ($rawId -match '(?i)/resourcegroups/([^/]+)') { $rg = $Matches[1] }
        }

        # Synthesize entity ID when no ARM ID is available
        if (-not $canonicalId) {
            $fallbackSub = if ($subId -match '^[0-9a-fA-F-]{36}$') {
                $subId.ToLowerInvariant()
            } else {
                '00000000-0000-0000-0000-000000000000'
            }
            $fallbackArmId = "/subscriptions/$fallbackSub/providers/microsoft.resourcegraph/azqrfindings/$findingId"
            $canonicalMeta = ConvertTo-CanonicalEntityId -RawId $fallbackArmId -EntityType 'AzureResource'
            $canonicalId = $canonicalMeta.CanonicalId
        }

        $title = Get-PropertyValue $finding 'Recommendation' (Get-PropertyValue $finding 'Title' (Get-PropertyValue $finding 'Description' 'Unknown'))
        $category = Get-PropertyValue $finding 'Category' (Get-PropertyValue $finding 'ServiceCategory' 'General')

        # Map severity from raw azqr values
        $rawSev = Get-PropertyValue $finding 'Severity' (Get-PropertyValue $finding 'Risk' 'Info')
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        # Determine compliance: azqr uses Result=OK or Compliant=$true
        $resultVal = Get-PropertyValue $finding 'Result' ''
        $compliantVal = Get-PropertyValue $finding 'Compliant' $null
        $compliant = ($resultVal -eq 'OK') -or ($compliantVal -eq $true)

        $detail = Get-PropertyValue $finding 'Notes' (Get-PropertyValue $finding 'Detail' (Get-PropertyValue $finding 'Description' ''))
        $remediation = Get-PropertyValue $finding 'Remediation' (Get-PropertyValue $finding 'Url' '')
        $learnMore = Get-PropertyValue $finding 'LearnMoreLink' (Get-PropertyValue $finding 'LearnMoreUrl' (Get-PropertyValue $finding 'Url' ''))

        $row = New-FindingRow -Id ([guid]::NewGuid().ToString()) `
            -Source 'azqr' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
