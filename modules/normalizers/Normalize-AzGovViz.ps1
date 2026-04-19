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
        $category = Get-PropertyValue $finding 'Category' 'Governance'
        $principalId = Get-PropertyValue $finding 'PrincipalId' ''
        $principalType = Get-PropertyValue $finding 'PrincipalType' ''
        $subId = ''
        $rg = ''
        $canonicalId = ''
        $entityType = 'ManagementGroup'
        $platformOverride = $null

        if ($category -eq 'Identity' -and $principalId) {
            $principalTypeValue = $principalType.ToLowerInvariant()
            # AzGovViz PrincipalId is always an objectId; prefix it for the canonicalizer
            $prefixedId = if ($principalId -match '^(objectId|appId):') { $principalId } else { "objectId:$principalId" }
            if ($principalTypeValue -match 'user') {
                $entityType = 'User'
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $prefixedId -EntityType 'User').CanonicalId
            } else {
                $entityType = 'ServicePrincipal'
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $prefixedId -EntityType 'ServicePrincipal').CanonicalId
            }
            # AzGovViz Identity findings represent Azure RBAC assignments.
            $platformOverride = 'Azure'
        }

        if (-not $canonicalId -and $rawId -and $rawId -match '^/subscriptions/') {
            # Bare /subscriptions/{id} → Subscription; deeper paths → AzureResource
            if ($rawId -match '^/subscriptions/[^/]+$') {
                $entityType = 'Subscription'
                # For Subscription EntityType, EntityId is just the GUID
                if ($rawId -match '/subscriptions/([^/]+)') {
                    $canonicalId = $Matches[1].ToLowerInvariant()
                }
            } else {
                $entityType = 'AzureResource'
                # For AzureResource, use full ARM path
                try {
                    $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
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

        $newFindingParams = @{
            Id              = ([guid]::NewGuid().ToString())
            Source          = 'azgovviz'
            EntityId        = $canonicalId
            EntityType      = $entityType
            Title           = $title
            Compliant       = [bool]$compliant
            ProvenanceRunId = $runId
            Category        = $category
            Severity        = $severity
            Detail          = $detail
            Remediation     = $remediation
            LearnMoreUrl    = ($learnMore ?? '')
            ResourceId      = ($rawId ?? '')
            SubscriptionId  = $subId
            ResourceGroup   = $rg
        }
        if ($platformOverride) {
            $newFindingParams.Platform = $platformOverride
        }

        $row = New-FindingRow @newFindingParams
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
