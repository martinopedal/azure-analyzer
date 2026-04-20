#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-GhActionsBilling {
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

    foreach ($finding in @($ToolResult.Findings)) {
        $rawId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) { [string]$finding.ResourceId } else { '' }
        if ([string]::IsNullOrWhiteSpace($rawId)) { continue }

        $canonicalId = $rawId.ToLowerInvariant()
        try {
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'Repository').CanonicalId
        } catch {
            $canonicalId = $rawId.ToLowerInvariant()
        }

        $severity = switch -Regex ([string]$finding.Severity) {
            '^(?i)critical$' { 'Critical' }
            '^(?i)high$'     { 'High' }
            '^(?i)medium$'   { 'Medium' }
            '^(?i)low$'      { 'Low' }
            default          { 'Info' }
        }

        $ruleId = if ($finding.PSObject.Properties['RuleId'] -and $finding.RuleId) { [string]$finding.RuleId } else { '' }
        $row = New-FindingRow -Id ([string]$finding.Id) `
            -Source 'gh-actions-billing' -EntityId $canonicalId -EntityType 'Repository' `
            -Title ([string]$finding.Title) -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category ([string]$finding.Category) -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId $rawId -RuleId $ruleId

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
