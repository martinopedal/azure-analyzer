#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for ALZ Resource Graph query findings.
.DESCRIPTION
    Converts raw alz-queries wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=AzureResource.
    ALZ findings have: Id, Title, Category, Severity, Compliant, Detail, ResourceId, LearnMoreUrl.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-AlzQueries {
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
        $rawId = ''
        if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            $rawId = [string]$finding.ResourceId
        }

        $subId = ''
        $rg = ''
        $canonicalId = ''

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
            if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }
        }

        # Use query GUID as fallback entity ID
        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $canonicalId = "alz-queries/$findingId"
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'ALZ' }
        $severity = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { $finding.Severity } else { 'Medium' }

        # Validate severity is in the allowed set
        if ($severity -notin @('Critical', 'High', 'Medium', 'Low', 'Info')) {
            $severity = switch -Regex ($severity.ToString().ToLowerInvariant()) {
                'critical'         { 'Critical' }
                'high'             { 'High' }
                'medium|moderate'  { 'Medium' }
                'low'              { 'Low' }
                'info'             { 'Info' }
                default            { 'Medium' }
            }
        }

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $true }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { $finding.Detail } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { $finding.LearnMoreUrl } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'alz-queries' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation '' `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
