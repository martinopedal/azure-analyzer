#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for zizmor findings.
.DESCRIPTION
    Converts raw zizmor wrapper output to v3 FindingRow objects.
    Platform=GitHub, EntityType=Workflow.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-Zizmor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult,
        [System.Collections.Generic.List[psobject]] $EdgeCollector
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    function ConvertTo-StringArray {
        param([object] $Value)
        $values = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $values.Add($text.Trim())
        }
        return @($values | Select-Object -Unique)
    }

    function Get-ZizmorRuleIdFromTitle {
        param([string] $Title)
        if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
        if ($Title -match '^(?<rule>[a-z0-9-]+)\s*:') {
            return $Matches['rule']
        }
        return ''
    }

    function ConvertTo-RemediationSnippets {
        param([object] $Value)

        $snippets = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($item in @($Value)) {
            if ($null -eq $item) { continue }
            $entry = @{}
            if ($item -is [System.Collections.IDictionary]) {
                foreach ($key in $item.Keys) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$key) -and $null -ne $item[$key]) {
                        $entry[[string]$key] = [string]$item[$key]
                    }
                }
            } else {
                foreach ($prop in @($item.PSObject.Properties)) {
                    if ($null -ne $prop.Value) {
                        $entry[[string]$prop.Name] = [string]$prop.Value
                    }
                }
            }
            if ($entry.Count -eq 0) { continue }
            if (-not $entry.ContainsKey('language')) { $entry['language'] = 'yaml' }
            if (-not ($entry.ContainsKey('code') -or ($entry.ContainsKey('before') -and $entry.ContainsKey('after')))) { continue }
            $snippets.Add($entry) | Out-Null
        }
        return @($snippets)
    }

    function Get-ZizmorEntityId {
        param(
            [object] $Finding,
            [string[]] $EntityRefs,
            [string[]] $EvidenceUris
        )

        foreach ($entityRef in @($EntityRefs)) {
            $normalized = ([string]$entityRef).Trim() -replace '\\', '/'
            if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
            $normalized = $normalized -replace '^https?://github\.com/', ''
            $normalized = $normalized -replace '^\.?/', ''
            if ($normalized -match '^[^/]+/[^/]+/.+') {
                return $normalized.ToLowerInvariant()
            }
        }

        foreach ($evidenceUri in @($EvidenceUris)) {
            if (-not $evidenceUri) { continue }
            if ($evidenceUri -match 'https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/blob/[^/]+/(?<path>[^#]+)') {
                return "$($Matches['owner'])/$($Matches['repo'])/$($Matches['path'])".ToLowerInvariant()
            }
        }

        $rawId = ''
        if ($Finding.PSObject.Properties['ResourceId'] -and $Finding.ResourceId) {
            $rawId = [string]$Finding.ResourceId
        }
        if ($rawId) {
            $rawId = $rawId.Trim().ToLowerInvariant() -replace '\\', '/'
            $rawId = $rawId -replace '^\.\/', ''
            return $rawId
        }

        return "zizmor/$([guid]::NewGuid().ToString())"
    }

    function Get-ZizmorImpactFromSeverity {
        param([string] $Severity)
        switch -Regex (($Severity ?? '').ToLowerInvariant()) {
            'critical' { return 'Critical' }
            'high' { return 'High' }
            'medium|moderate' { return 'Medium' }
            'low' { return 'Low' }
            'info' { return 'Info' }
            default { return 'Medium' }
        }
    }

    function Add-ZizmorTrackAEdges {
        param([object] $Candidate)
        if ($null -eq $EdgeCollector) { return }
        if ($null -eq $Candidate -or -not $Candidate.PSObject.Properties['AttackPathEdges']) { return }
        $allowedRelations = @('TriggeredBy', 'AuthenticatesAs', 'DeploysTo', 'UsesSecret', 'HasFederatedCredential', 'Declares')
        foreach ($edgeHint in @($Candidate.AttackPathEdges)) {
            if ($null -eq $edgeHint) { continue }
            $source = if ($edgeHint.PSObject.Properties['Source']) { [string]$edgeHint.Source } else { '' }
            $target = if ($edgeHint.PSObject.Properties['Target']) { [string]$edgeHint.Target } else { '' }
            $relation = if ($edgeHint.PSObject.Properties['Relation']) { [string]$edgeHint.Relation } else { '' }
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) { continue }
            if ($relation -notin $allowedRelations) { continue }
            $edge = New-Edge -Source $source -Target $target -Relation $relation -Confidence 'Likely' -Platform 'GitHub' -DiscoveredBy 'zizmor'
            if ($null -ne $edge) { $EdgeCollector.Add($edge) | Out-Null }
        }
    }

    foreach ($finding in $ToolResult.Findings) {
        Add-ZizmorTrackAEdges -Candidate $finding
        $rawId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) { [string]$finding.ResourceId } else { '' }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'CI/CD Security' }
        $ruleId = if ($finding.PSObject.Properties['RuleId'] -and $finding.RuleId) { [string]$finding.RuleId } else { Get-ZizmorRuleIdFromTitle -Title ([string]$title) }

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
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else { Get-ZizmorImpactFromSeverity -Severity $severity }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else { if ($ruleId -eq 'unpinned-uses') { 'Medium' } else { 'Low' } }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }
        $remediationSnippets = if ($finding.PSObject.Properties['RemediationSnippets'] -and $finding.RemediationSnippets) { ConvertTo-RemediationSnippets -Value $finding.RemediationSnippets } else { @() }
        $evidenceUris = if ($finding.PSObject.Properties['EvidenceUris'] -and $finding.EvidenceUris) { ConvertTo-StringArray -Value $finding.EvidenceUris } else { @() }
        $baselineTags = if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) { ConvertTo-StringArray -Value $finding.BaselineTags } else { @() }
        $mitreTactics = if ($finding.PSObject.Properties['MitreTactics'] -and $finding.MitreTactics) { ConvertTo-StringArray -Value $finding.MitreTactics } else { @() }
        $mitreTechniques = if ($finding.PSObject.Properties['MitreTechniques'] -and $finding.MitreTechniques) { ConvertTo-StringArray -Value $finding.MitreTechniques } else { @() }
        $entityRefs = if ($finding.PSObject.Properties['EntityRefs'] -and $finding.EntityRefs) { ConvertTo-StringArray -Value $finding.EntityRefs } else { @() }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) { [string]$ToolResult.ToolVersion } else { '' }

        if (@($baselineTags).Count -eq 0) {
            if ($ruleId) { $baselineTags += $ruleId }
            $baselineTags += "severity:$($severity.ToLowerInvariant())"
        }
        if (@($entityRefs).Count -eq 0 -and $rawId) {
            $entityRefs = @($rawId -replace '\\', '/')
        }
        if ([string]::IsNullOrWhiteSpace($deepLinkUrl) -and $ruleId) {
            $deepLinkUrl = "https://docs.zizmor.sh/audits/#$ruleId"
        }
        if ([string]::IsNullOrWhiteSpace($deepLinkUrl) -and @($evidenceUris).Count -gt 0) {
            $deepLinkUrl = $evidenceUris[0]
        }
        if ([string]::IsNullOrWhiteSpace($learnMore) -and -not [string]::IsNullOrWhiteSpace($deepLinkUrl)) {
            $learnMore = $deepLinkUrl
        }
        if (@($mitreTechniques).Count -eq 0) {
            switch (($ruleId ?? '').ToLowerInvariant()) {
                'template-injection' { $mitreTechniques = @('T1059') }
                'expression-injection' { $mitreTechniques = @('T1059') }
                'unpinned-uses' { $mitreTechniques = @('T1195.001') }
            }
        }

        $canonicalId = Get-ZizmorEntityId -Finding $finding -EntityRefs $entityRefs -EvidenceUris $evidenceUris

        $row = New-FindingRow -Id $findingId `
            -Source 'zizmor' -EntityId $canonicalId -EntityType 'Workflow' `
            -Title $title -RuleId $ruleId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets $remediationSnippets `
            -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags `
            -MitreTactics $mitreTactics `
            -MitreTechniques $mitreTechniques `
            -EntityRefs $entityRefs `
            -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
