#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for ADO pipeline security findings.
.DESCRIPTION
    Converts raw ADO pipeline security wrapper output into v2 FindingRow objects.
    Uses first-class ADO entity types for pipelines, variable groups, environments,
    and service connections when the wrapper provides that asset metadata.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADOPipelineSecurity {
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
        $assetType = if ($finding.PSObject.Properties['AssetType'] -and $finding.AssetType) {
            [string]$finding.AssetType
        } else {
            'Pipeline'
        }

        $entityType = switch -Regex ($assetType.ToLowerInvariant()) {
            '^variablegroup$' { 'VariableGroup' }
            '^environment$' { 'Environment' }
            '^serviceconnection$' { 'ServiceConnection' }
            default { 'Pipeline' }
        }

        $resourceId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            [string]$finding.ResourceId
        } else {
            ''
        }

        $canonicalId = ''
        if ($resourceId) {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $resourceId -EntityType $entityType).CanonicalId
            } catch {
                $canonicalId = $resourceId.ToLowerInvariant()
            }
        }

        if (-not $canonicalId) {
            $org = if ($finding.PSObject.Properties['AdoOrg']) { [string]$finding.AdoOrg } else { 'unknown' }
            $project = if ($finding.PSObject.Properties['AdoProject']) { [string]$finding.AdoProject } else { 'unknown' }
            $assetName = if ($finding.PSObject.Properties['AssetName']) { [string]$finding.AssetName } else { 'unknown' }
            $canonicalId = "ado://$($org.ToLowerInvariant())/$($project.ToLowerInvariant())/$($assetType.ToLowerInvariant())/$($assetName.ToLowerInvariant())"
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $severity = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) {
            switch -Regex ([string]$finding.Severity) {
                '^(?i)critical$' { 'Critical' }
                '^(?i)high$'     { 'High' }
                '^(?i)medium$'   { 'Medium' }
                '^(?i)low$'      { 'Low' }
                '^(?i)info'      { 'Info' }
                default          { 'Info' }
            }
        } else {
            'Info'
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'ado-pipelines' -EntityId $canonicalId -EntityType $entityType `
            -Title ([string]$finding.Title) -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category ([string]$finding.Category) -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId $resourceId

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
