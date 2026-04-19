#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for identity correlator findings.
.DESCRIPTION
    Converts raw identity correlator findings into v2 FindingRow objects
    via New-FindingRow, with canonical entity IDs for User/ServicePrincipal.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-IdentityCorrelation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()
    $runId = if ($ToolResult.PSObject.Properties['RunId'] -and $ToolResult.RunId) { $ToolResult.RunId } else { [guid]::NewGuid().ToString() }

    foreach ($finding in $ToolResult.Findings) {
        if (-not $finding) { continue }

        # Determine EntityType from the finding's PrincipalType (or fall back)
        $entityType = 'ServicePrincipal'
        if ($finding.PSObject.Properties['EntityType'] -and $finding.EntityType) {
            $entityType = [string]$finding.EntityType
        } elseif ($finding.PSObject.Properties['PrincipalType'] -and $finding.PrincipalType) {
            $pt = ([string]$finding.PrincipalType).ToLowerInvariant()
            if ($pt -match 'user') { $entityType = 'User' }
        }

        $rawEntityId = if ($finding.PSObject.Properties['EntityId'] -and $finding.EntityId) { [string]$finding.EntityId } else { '' }
        $canonicalId = $rawEntityId
        if ($rawEntityId) {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawEntityId -EntityType $entityType).CanonicalId
            } catch {
                $canonicalId = $rawEntityId.ToLowerInvariant()
            }
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) { [string]$finding.Id } else { [guid]::NewGuid().ToString() }
        $title     = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { [string]$finding.Title } else { 'Identity correlation finding' }
        $compliant = if ($finding.PSObject.Properties['Compliant'] -and $null -ne $finding.Compliant) { [bool]$finding.Compliant } else { $false }
        $severity  = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { [string]$finding.Severity } else { 'Info' }
        $category  = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { [string]$finding.Category } else { 'Identity' }
        $detail    = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { [string]$finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { [string]$finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { [string]$finding.LearnMoreUrl } else { '' }
        $resourceId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) { [string]$finding.ResourceId } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'identity-correlator' -EntityId $canonicalId -EntityType $entityType `
            -Title $title -Compliant $compliant -ProvenanceRunId $runId `
            -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $resourceId

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
