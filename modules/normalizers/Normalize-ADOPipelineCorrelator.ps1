#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADOPipelineCorrelator {
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
        $pipelineIdRaw = if ($finding.PSObject.Properties['PipelineResourceId'] -and $finding.PipelineResourceId) {
            [string]$finding.PipelineResourceId
        } else {
            'ado://unknown/unknown/pipeline/unknown'
        }

        $entityId = ''
        try {
            $entityId = (ConvertTo-CanonicalEntityId -RawId $pipelineIdRaw -EntityType 'Pipeline').CanonicalId
        } catch {
            $entityId = $pipelineIdRaw.ToLowerInvariant()
        }

        $severity = switch -Regex ([string]$finding.Severity) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            '^(?i)info$'     { 'Info' }
            default          { 'Info' }
        }

        $row = New-FindingRow -Id ([string]$finding.Id) `
            -Source 'ado-pipeline-correlator' -EntityId $entityId -EntityType 'Pipeline' `
            -Title ([string]$finding.Title) -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category 'Pipeline Run Correlation' -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId ([string]$finding.ResourceId)

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
