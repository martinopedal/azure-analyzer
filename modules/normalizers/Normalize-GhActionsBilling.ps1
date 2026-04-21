#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Convert-ToStringArray {
    param ([object]$Value)

    if ($null -eq $Value) { return @() }
    $items = [System.Collections.Generic.List[string]]::new()
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) { $items.Add($Value.Trim()) | Out-Null }
    } else {
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) { $items.Add($text.Trim()) | Out-Null }
        }
    }
    return @($items)
}

function Convert-ToHashtableArray {
    param ([object]$Value)

    $items = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @($Value)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [System.Collections.IDictionary]) {
            $map = @{}
            foreach ($key in $entry.Keys) { $map[[string]$key] = $entry[$key] }
            $items.Add($map) | Out-Null
            continue
        }
        if ($entry.PSObject -and @($entry.PSObject.Properties).Count -gt 0) {
            $map = @{}
            foreach ($prop in @($entry.PSObject.Properties)) { $map[$prop.Name] = $prop.Value }
            $items.Add($map) | Out-Null
        }
    }
    return @($items)
}

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
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { '' }
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else { '' }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else { '' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } else { '' }
        $scoreDelta = $null
        if ($finding.PSObject.Properties['ScoreDelta'] -and $null -ne $finding.ScoreDelta) {
            try { $scoreDelta = [double]$finding.ScoreDelta } catch {}
        }
        $evidenceUris = @(Convert-ToStringArray $(if ($finding.PSObject.Properties['EvidenceUris']) { $finding.EvidenceUris } else { @() }))
        $baselineTags = @(Convert-ToStringArray $(if ($finding.PSObject.Properties['BaselineTags']) { $finding.BaselineTags } else { @() }))
        $entityRefs = @(Convert-ToStringArray $(if ($finding.PSObject.Properties['EntityRefs']) { $finding.EntityRefs } else { @() }))
        $remediationSnippets = @(Convert-ToHashtableArray $(if ($finding.PSObject.Properties['RemediationSnippets']) { $finding.RemediationSnippets } else { @() }))

        $row = New-FindingRow -Id ([string]$finding.Id) `
            -Source 'gh-actions-billing' -EntityId $canonicalId -EntityType 'Repository' `
            -Title ([string]$finding.Title) -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category ([string]$finding.Category) -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId $rawId -RuleId $ruleId `
            -Pillar $pillar -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets $remediationSnippets -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags -ScoreDelta $scoreDelta -EntityRefs $entityRefs `
            -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
