#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for zizmor findings.
.DESCRIPTION
    Converts raw zizmor wrapper output to v3 FindingRow objects.
    Platform=GitHub, EntityType=Workflow.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-Zizmor {
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

        # Canonicalize workflow file path: lowercase, forward-slash, strip leading ./
        $canonicalId = ''
        if ($rawId) {
            $canonicalId = $rawId.Trim().ToLowerInvariant() -replace '\\', '/'
            $canonicalId = $canonicalId -replace '^\.\/', ''
        }
        if (-not $canonicalId) {
            $canonicalId = "zizmor/$([guid]::NewGuid().ToString())"
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'CI/CD Security' }

        $rawSev = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { $finding.Severity } else { 'Medium' }
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $false }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { $finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { $finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { $finding.LearnMoreUrl } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'zizmor' -EntityId $canonicalId -EntityType 'Workflow' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '')
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
