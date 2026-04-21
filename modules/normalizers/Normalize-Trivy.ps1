#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Aqua Security Trivy findings.
.DESCRIPTION
    Converts raw Trivy wrapper output to v3 FindingRow objects.
    Platform=GitHub, EntityType=Repository.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function ConvertTo-HashtableArray {
    param([object[]] $Items)
    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        if ($item -is [hashtable]) {
            $result.Add($item) | Out-Null
            continue
        }
        $table = @{}
        foreach ($property in $item.PSObject.Properties) {
            $table[$property.Name] = $property.Value
        }
        if ($table.Count -gt 0) { $result.Add($table) | Out-Null }
    }
    return @($result)
}

function Normalize-Trivy {
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

        $canonicalId = ''
        if ($rawId) {
            if ($rawId -match '(?i)^(sha256:[a-f0-9]{64})$') {
                $canonicalId = "trivy/image/$($Matches[1].ToLowerInvariant())"
            } elseif ($rawId -match '(?i)(sha256:[a-f0-9]{64})') {
                $canonicalId = "trivy/image/$($Matches[1].ToLowerInvariant())"
            } else {
                try {
                    $canonicalId = ConvertTo-CanonicalRepoId -RepoId $rawId
                } catch {
                    $canonicalId = "trivy/$($rawId.ToLowerInvariant() -replace '\\', '/' -replace '^\./?', '')"
                    if ($canonicalId -eq 'trivy/') { $canonicalId = 'trivy/local' }
                }
            }
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $canonicalId = "trivy/$findingId"
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'Supply Chain' }
        $ruleId = if ($finding.PSObject.Properties['RuleId'] -and $finding.RuleId) { [string]$finding.RuleId } else { '' }

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
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Security' }
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else { '' }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else { '' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }
        $frameworks = if ($finding.PSObject.Properties['Frameworks'] -and $finding.Frameworks) { ConvertTo-HashtableArray -Items @($finding.Frameworks) } else { @() }
        $evidenceUris = if ($finding.PSObject.Properties['EvidenceUris'] -and $finding.EvidenceUris) { @([string[]]$finding.EvidenceUris) } else { @() }
        $baselineTags = if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) { @([string[]]$finding.BaselineTags) } else { @() }
        $entityRefs = if ($finding.PSObject.Properties['EntityRefs'] -and $finding.EntityRefs) { @([string[]]$finding.EntityRefs) } else { @() }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } else { '' }
        $remediationSnippets = if ($finding.PSObject.Properties['RemediationSnippets'] -and $finding.RemediationSnippets) { ConvertTo-HashtableArray -Items @($finding.RemediationSnippets) } else { @() }
        $scoreDelta = $null
        if ($finding.PSObject.Properties['ScoreDelta'] -and $null -ne $finding.ScoreDelta) {
            try { $scoreDelta = [double]$finding.ScoreDelta } catch { $scoreDelta = $null }
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'trivy' -EntityId $canonicalId -EntityType 'Repository' `
            -Title $title -RuleId $ruleId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -Pillar $pillar -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -Frameworks @($frameworks) -EvidenceUris @($evidenceUris) `
            -BaselineTags @($baselineTags) -RemediationSnippets @($remediationSnippets) `
            -ScoreDelta $scoreDelta -EntityRefs @($entityRefs) -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
