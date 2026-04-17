#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for AzGovViz findings.
.DESCRIPTION
    Converts raw AzGovViz wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=ManagementGroup or AzureResource depending on the finding.
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

function Normalize-AzGovViz {
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
        $rawId = Get-PropertyValue $finding 'ResourceId' ''
        $subId = ''
        $rg = ''
        $canonicalId = ''
        $entityType = 'ManagementGroup'

        if ($rawId -and $rawId -match '^/subscriptions/') {
            # Bare /subscriptions/{id} → Subscription; deeper paths → AzureResource
            if ($rawId -match '^/subscriptions/[^/]+$') {
                $entityType = 'Subscription'
                # For Subscription EntityType, EntityId must be just the GUID
                if ($rawId -match '/subscriptions/([^/]+)') {
                    $canonicalId = $Matches[1].ToLowerInvariant()
                }
            } else {
                $entityType = 'AzureResource'
                try {
                    $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId
                } catch {
                    $canonicalId = $rawId.ToLowerInvariant()
                }
            }
            if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
            if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }
        }

        if (-not $canonicalId) {
            # For MG findings, build a stable ID from Category+Title instead of random GUID
            $mgId = Get-PropertyValue $finding 'ManagementGroupId' ''
            if ($mgId) {
                $canonicalId = "azgovviz/mg/$($mgId.ToLowerInvariant())"
            } else {
                $cat  = Get-PropertyValue $finding 'Category' 'unknown'
                $ttl  = Get-PropertyValue $finding 'Title' (Get-PropertyValue $finding 'Description' 'unknown')
                $stableKey = "$cat/$ttl".ToLowerInvariant() -replace '[^a-z0-9/]', '-'
                $canonicalId = "azgovviz/$stableKey"
            }
            # For management group findings, keep the ManagementGroup type
            $entityType = 'ManagementGroup'
        }

        $title = Get-PropertyValue $finding 'Title' (Get-PropertyValue $finding 'Description' 'Unknown')
        $category = Get-PropertyValue $finding 'Category' 'Governance'

        $rawSev = Get-PropertyValue $finding 'Severity' 'Info'
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        # Determine compliance
        $compliantProp = $finding.PSObject.Properties['Compliant']
        $compliant = if ($null -eq $compliantProp) { $true } else { $compliantProp.Value -ne $false }

        $detail = Get-PropertyValue $finding 'Detail' ''
        $remediation = Get-PropertyValue $finding 'Remediation' ''
        $learnMore = Get-PropertyValue $finding 'LearnMoreUrl' (Get-PropertyValue $finding 'LearnMoreLink' '')

        $row = New-FindingRow -Id ([guid]::NewGuid().ToString()) `
            -Source 'azgovviz' -EntityId $canonicalId -EntityType $entityType `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl ($learnMore ?? '') -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg
        $normalized.Add($row)
    }

    return @($normalized)
}
