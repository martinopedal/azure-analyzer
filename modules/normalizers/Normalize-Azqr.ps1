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

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
            if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }
        }

        # Synthesize entity ID when no ARM ID is available
        $findingId = Get-PropertyValue $finding 'Id' ([guid]::NewGuid().ToString())
        if (-not $canonicalId) {
            $canonicalId = "azqr/$findingId"
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
        $normalized.Add($row)
    }

    return @($normalized)
}
