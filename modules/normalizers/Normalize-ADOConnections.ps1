#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for ADO service connection findings.
.DESCRIPTION
    Converts raw ADO service connection wrapper output to v3 FindingRow objects.
    Platform=ADO, EntityType=ServiceConnection.
    CanonicalId = ado://{org}/{project}/serviceconnection/{name} (lowercased).
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADOConnections {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -notin @('Success', 'PartialSuccess') -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in $ToolResult.Findings) {
        # Extract org/project/name for canonical ID
        $org = if ($finding.PSObject.Properties['AdoOrg'] -and $finding.AdoOrg) {
            $finding.AdoOrg
        } else { 'unknown' }

        $project = if ($finding.PSObject.Properties['AdoProject'] -and $finding.AdoProject) {
            $finding.AdoProject
        } else { 'unknown' }

        $connType = if ($finding.PSObject.Properties['ConnectionType'] -and $finding.ConnectionType) {
            $finding.ConnectionType
        } else { 'Unknown' }

        $authScheme = if ($finding.PSObject.Properties['AuthScheme'] -and $finding.AuthScheme) {
            $finding.AuthScheme
        } else { 'Unknown' }

        $authMechanism = if ($finding.PSObject.Properties['AuthMechanism'] -and $finding.AuthMechanism) {
            $finding.AuthMechanism
        } else { 'Unknown' }

        $isShared = if ($finding.PSObject.Properties['IsShared']) {
            [bool]$finding.IsShared
        } else { $false }

        # Build canonical ID via the existing canonicalizer
        $rawResourceId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            [string]$finding.ResourceId
        } else { '' }

        $canonicalId = ''
        if ($rawResourceId) {
            try {
                $canonicalId = ConvertTo-CanonicalAdoId -AdoId $rawResourceId
            } catch {
                $canonicalId = $rawResourceId.ToLowerInvariant()
            }
        }
        if (-not $canonicalId) {
            # Fallback: construct from parts
            $canonicalId = "ado://$($org.ToLowerInvariant())/$($project.ToLowerInvariant())/serviceconnection/unknown"
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) {
            $finding.Title
        } else { 'Unknown service connection' }

        $category = 'Service Connection'
        $severity = 'Info'
        $compliant = $true

        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) {
            $finding.Detail
        } else {
            "Type=$connType; AuthScheme=$authScheme; AuthMechanism=$authMechanism; IsShared=$isShared"
        }

        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) {
            $finding.Remediation
        } else { '' }

        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) {
            $finding.LearnMoreUrl
        } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'ado-connections' -EntityId $canonicalId -EntityType 'ServiceConnection' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawResourceId)
        $normalized.Add($row)
    }

    return @($normalized)
}
