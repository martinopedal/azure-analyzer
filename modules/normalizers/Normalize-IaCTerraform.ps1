#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Terraform IaC validation findings.
.DESCRIPTION
    Converts raw Terraform wrapper output to v2 FindingRow objects.
    Platform=GitHub, EntityType=Repository.

    Findings carry Source = terraform-iac with subkeys validate and trivy-config
    in the Category field so the existing report grouping renders cleanly.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-IaCTerraform {
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

        # For IaC validation, ResourceId is a directory path within the repo.
        # Try to parse as a GitHub repo ID first; fall back to a synthetic
        # 3-segment ID that passes ConvertTo-CanonicalRepoId validation.
        $canonicalId = ''
        if ($rawId) {
            try {
                $canonicalId = ConvertTo-CanonicalRepoId -RepoId $rawId
            } catch {
                # Not a repo URL - build synthetic host/owner/repo ID
                # Flatten path separators to dashes so it remains a single segment
                $slug = $rawId.ToLowerInvariant() -replace '\\', '/' -replace '^\./?', ''
                $slug = $slug -replace '/', '--' -replace '[^a-z0-9\-\.]', '-'
                if (-not $slug -or $slug -eq '.') { $slug = 'root' }
                $canonicalId = "iac.local/terraform-iac/$slug"
            }
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $canonicalId = "iac.local/terraform-iac/$findingId"
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'IaC Validation' }

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
            -Source 'terraform-iac' -EntityId $canonicalId -EntityType 'Repository' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '')
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
