#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADORepoSecrets {
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
        $repoIdRaw = if ($finding.PSObject.Properties['RepositoryCanonicalId'] -and $finding.RepositoryCanonicalId) {
            [string]$finding.RepositoryCanonicalId
        } else {
            'ado://unknown/unknown/repository/unknown'
        }

        $entityId = ''
        try {
            $entityId = (ConvertTo-CanonicalEntityId -RawId $repoIdRaw -EntityType 'Repository').CanonicalId
        } catch {
            $entityId = $repoIdRaw.ToLowerInvariant()
        }

        $severity = switch -Regex ([string]$finding.Severity) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            '^(?i)info$'     { 'Info' }
            default          { 'Info' }
        }

        $resourceId = ''
        if ($finding.PSObject.Properties['FilePath'] -and $finding.FilePath) {
            $resourceId = ([string]$finding.FilePath).Trim().ToLowerInvariant() -replace '\\', '/'
        }

        $confidence = if ($finding.PSObject.Properties['Confidence'] -and $finding.Confidence) {
            [string]$finding.Confidence
        } else {
            'Unknown'
        }

        $row = New-FindingRow -Id ([string]$finding.Id) `
            -Source 'ado-repos-secrets' -EntityId $entityId -EntityType 'Repository' `
            -Title ([string]$finding.Title) -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'ADO' -Category 'Secret Detection' -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId $resourceId `
            -Confidence $confidence

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
