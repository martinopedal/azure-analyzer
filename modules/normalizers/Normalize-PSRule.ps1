#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for PSRule for Azure findings.
.DESCRIPTION
    Converts PSRule wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=AzureResource.
    The wrapper already standardises to v1 fields: Title, Category, Compliant,
    Severity, Detail, Remediation, ResourceId, LearnMoreUrl.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-PSRule {
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

    function Get-RemediationSnippets {
        param([string] $Recommendation)
        if ([string]::IsNullOrWhiteSpace($Recommendation)) {
            return @()
        }

        $snippets = [System.Collections.Generic.List[hashtable]]::new()
        $matches = [regex]::Matches($Recommendation, '(?ms)```(?<language>[^\r\n`]*)\r?\n(?<code>.*?)```')
        foreach ($match in $matches) {
            $code = [string]$match.Groups['code'].Value
            if ([string]::IsNullOrWhiteSpace($code)) { continue }
            $language = [string]$match.Groups['language'].Value
            if ([string]::IsNullOrWhiteSpace($language)) { $language = 'text' }
            $snippets.Add(@{
                    language = $language.Trim().ToLowerInvariant()
                    code     = $code.Trim()
                }) | Out-Null
        }

        if ($snippets.Count -eq 0) {
            $snippets.Add(@{
                    language = 'text'
                    code     = $Recommendation.Trim()
                }) | Out-Null
        }

        return @($snippets)
    }

    foreach ($finding in $ToolResult.Findings) {
        $rawId = ''
        if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) {
            $rawId = [string]$finding.ResourceId
        }

        $subId = ''
        $rg = ''
        $canonicalId = ''

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
            if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $canonicalId = "psrule/$findingId"
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'PSRule' }

        $rawSev = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { $finding.Severity } else { 'Medium' }
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $true }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { $finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { $finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { $finding.LearnMoreUrl } else { '' }
        $ruleId = if ($finding.PSObject.Properties['RuleId'] -and $finding.RuleId) { [string]$finding.RuleId } else { $category }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { '' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }
        $frameworks = if ($finding.PSObject.Properties['Frameworks'] -and $finding.Frameworks) { @($finding.Frameworks) } else { @() }
        $baselineTags = if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) { @($finding.BaselineTags) } else { @() }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } else { '' }
        $remediationSnippets = Get-RemediationSnippets -Recommendation $remediation

        # Track D enrichment (#432b): derive Impact/Effort, surface evidence URIs,
        # pass through MITRE + ScoreDelta, and seed EntityRefs with subscription scope.
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else {
            switch ($severity) { 'Critical' { 'High' } 'High' { 'High' } 'Medium' { 'Medium' } default { 'Low' } }
        }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else {
            switch ($severity) { 'Critical' { 'High' } 'High' { 'Medium' } 'Medium' { 'Medium' } default { 'Low' } }
        }
        $evidenceUris = [System.Collections.Generic.List[string]]::new()
        if ($finding.PSObject.Properties['EvidenceUris'] -and $finding.EvidenceUris) {
            foreach ($u in @($finding.EvidenceUris)) { if (-not [string]::IsNullOrWhiteSpace([string]$u)) { $evidenceUris.Add([string]$u) | Out-Null } }
        }
        foreach ($u in @($learnMore, $deepLinkUrl)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$u) -and ($evidenceUris -notcontains [string]$u)) {
                $evidenceUris.Add([string]$u) | Out-Null
            }
        }
        $mitreTactics = if ($finding.PSObject.Properties['MitreTactics'] -and $finding.MitreTactics) { @([string[]]$finding.MitreTactics) } else { @() }
        $mitreTechniques = if ($finding.PSObject.Properties['MitreTechniques'] -and $finding.MitreTechniques) { @([string[]]$finding.MitreTechniques) } else { @() }
        $scoreDelta = $null
        if ($finding.PSObject.Properties['ScoreDelta'] -and $null -ne $finding.ScoreDelta) {
            try { $scoreDelta = [double]$finding.ScoreDelta } catch { $scoreDelta = $null }
        }
        $entityRefs = [System.Collections.Generic.List[string]]::new()
        if ($finding.PSObject.Properties['EntityRefs'] -and $finding.EntityRefs) {
            foreach ($r in @($finding.EntityRefs)) { if (-not [string]::IsNullOrWhiteSpace([string]$r)) { $entityRefs.Add([string]$r) | Out-Null } }
        }
        if ($subId) {
            try {
                $subRef = (ConvertTo-CanonicalEntityId -RawId $subId -EntityType 'Subscription').CanonicalId
                if ($subRef -and $entityRefs -notcontains $subRef) { $entityRefs.Add($subRef) | Out-Null }
            } catch { } # best-effort: malformed subscriptionId; skip enrichment, keep raw finding
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'psrule'-EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -RuleId $ruleId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Frameworks $frameworks -Pillar $pillar -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets $remediationSnippets -BaselineTags $baselineTags `
            -Impact $impact -Effort $effort -EvidenceUris @($evidenceUris) `
            -MitreTactics @($mitreTactics) -MitreTechniques @($mitreTechniques) `
            -ScoreDelta $scoreDelta -EntityRefs @($entityRefs) `
            -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
