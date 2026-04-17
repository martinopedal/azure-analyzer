#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for gitleaks findings.
.DESCRIPTION
    Converts raw gitleaks wrapper output to v3 FindingRow objects.
    Platform=GitHub, EntityType=Repository.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-Gitleaks {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $repoIdRaw = @(
        $ToolResult.PSObject.Properties['RepositoryId']?.Value,
        $ToolResult.PSObject.Properties['Repository']?.Value,
        $ToolResult.PSObject.Properties['RepositoryUrl']?.Value,
        $ToolResult.PSObject.Properties['RemoteUrl']?.Value
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
    if (-not $repoIdRaw) {
        $repoIdRaw = 'github.com/local/local'
    }

    try {
        $repoMeta = ConvertTo-CanonicalEntityId -RawId ([string]$repoIdRaw) -EntityType 'Repository'
        $canonicalRepoId = $repoMeta.CanonicalId
    } catch {
        $canonicalRepoId = 'github.com/local/local'
    }

    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in $ToolResult.Findings) {
        $rawId = ''
        if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            $rawId = [string]$finding.ResourceId
        }

        $canonicalPath = ''
        if ($rawId) {
            $canonicalPath = $rawId.Trim().ToLowerInvariant() -replace '\\', '/'
            $canonicalPath = $canonicalPath -replace '^\.\/', ''
        }
        if (-not $canonicalPath) {
            $canonicalPath = "unknown/$([guid]::NewGuid().ToString())"
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Secret detected' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'Secret Detection' }

        $rawSev = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { $finding.Severity } else { 'High' }
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
            -Source 'gitleaks' -EntityId $canonicalRepoId -EntityType 'Repository' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $canonicalPath
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
