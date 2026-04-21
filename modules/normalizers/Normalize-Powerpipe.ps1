#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Powerpipe control-pack findings.
.DESCRIPTION
    Converts Powerpipe v1 wrapper output to schema v2.2 FindingRows, including
    additive framework and baseline metadata fields.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-PropertyValue {
    param ([object]$Obj, [string[]]$Names, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $Default
}

function Get-StringArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return @($Value | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

function Resolve-Severity {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return 'Medium' }
    switch -Regex ($Raw.ToLowerInvariant()) {
        'critical'         { 'Critical' }
        'high|alarm'       { 'High' }
        'medium|moderate'  { 'Medium' }
        'low'              { 'Low' }
        'info|ok|pass'     { 'Info' }
        default            { 'Medium' }
    }
}

function Resolve-Compliant {
    param([object]$Finding)
    $explicit = Get-PropertyValue -Obj $Finding -Names @('Compliant', 'compliant') -Default $null
    if ($null -ne $explicit) { return [bool]$explicit }
    $status = [string](Get-PropertyValue -Obj $Finding -Names @('Status', 'status') -Default '')
    return ($status -match '^(ok|pass|passed|compliant|skip|skipped)$')
}

function Resolve-Pillar {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $value = $Raw.ToLowerInvariant()
    if ($value -match 'security') { return 'Security' }
    if ($value -match 'cost|finops') { return 'Cost Optimization' }
    if ($value -match 'reliability|resilien') { return 'Reliability' }
    if ($value -match 'operat') { return 'Operational Excellence' }
    if ($value -match 'performance') { return 'Performance Efficiency' }
    return $Raw
}

function Resolve-Frameworks {
    param([object]$Finding, [object]$Tags)

    $list = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($framework in @(Get-PropertyValue -Obj $Finding -Names @('Frameworks', 'frameworks') -Default @())) {
        if ($null -eq $framework) { continue }
        $kind = [string](Get-PropertyValue -Obj $framework -Names @('kind', 'Kind', 'name', 'Name') -Default '')
        $controlId = [string](Get-PropertyValue -Obj $framework -Names @('controlId', 'ControlId', 'id', 'Id') -Default '')
        if ([string]::IsNullOrWhiteSpace($kind) -or [string]::IsNullOrWhiteSpace($controlId)) { continue }
        $key = "$kind|$controlId"
        if ($seen.Add($key)) { $list.Add(@{ kind = $kind; controlId = $controlId }) | Out-Null }
    }

    $excludedTagKeys = @(
        'pillar', 'category', 'impact', 'effort',
        'deep_link_url', 'deeplinkurl', 'documentation_url', 'url', 'doc_url',
        'remediation', 'remediation_doc',
        'evidence_uri', 'evidence_uris',
        'baseline', 'baseline_tags', 'release',
        'mitre_tactics', 'mitre_techniques'
    )

    foreach ($tp in @($Tags.PSObject.Properties)) {
        $tagKey = [string]$tp.Name
        if (-not $tagKey) { continue }
        if ($excludedTagKeys -contains $tagKey.ToLowerInvariant()) { continue }
        foreach ($ref in @(Get-StringArray -Value $tp.Value)) {
            $key = "$tagKey|$ref"
            if ($seen.Add($key)) {
                $list.Add(@{ kind = $tagKey.ToUpperInvariant(); controlId = $ref }) | Out-Null
            }
        }
    }

    return @($list)
}

function Normalize-Powerpipe {
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
    $toolVersion = [string](Get-PropertyValue -Obj $ToolResult -Names @('ToolVersion', 'toolVersion') -Default '')
    $defaultSub = [string](Get-PropertyValue -Obj $ToolResult -Names @('Subscription', 'SubscriptionId') -Default '')

    foreach ($finding in $ToolResult.Findings) {
        $rawId = [string](Get-PropertyValue -Obj $finding -Names @('ResourceId', 'resourceId') -Default '')
        $subId = $defaultSub
        $rg = ''
        $canonicalId = ''

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '(?i)/subscriptions/([^/]+)') { $subId = $Matches[1].ToLowerInvariant() }
            if ($rawId -match '(?i)/resourcegroups/([^/]+)') { $rg = $Matches[1] }
        }

        $controlId = [string](Get-PropertyValue -Obj $finding -Names @('ControlId', 'controlId', 'RuleId', 'ruleId', 'Id', 'id') -Default ([guid]::NewGuid().ToString()))
        if (-not $canonicalId) {
            $fallbackSub = if ($subId -match '^[0-9a-fA-F-]{36}$') { $subId.ToLowerInvariant() } else { '00000000-0000-0000-0000-000000000000' }
            $fallbackArm = "/subscriptions/$fallbackSub/providers/microsoft.security/powerpipeControls/$($controlId.ToLowerInvariant())"
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $fallbackArm -EntityType 'AzureResource').CanonicalId
        }

        $tags = Get-PropertyValue -Obj $finding -Names @('Tags', 'tags') -Default ([pscustomobject]@{})
        if ($null -eq $tags) { $tags = [pscustomobject]@{} }

        $title = [string](Get-PropertyValue -Obj $finding -Names @('Title', 'title', 'ControlTitle') -Default $controlId)
        $category = [string](Get-PropertyValue -Obj $finding -Names @('Category', 'category') -Default (Get-PropertyValue -Obj $tags -Names @('category') -Default 'Compliance'))
        $severity = Resolve-Severity -Raw ([string](Get-PropertyValue -Obj $finding -Names @('Severity', 'severity', 'Status', 'status') -Default 'Medium'))
        $compliant = Resolve-Compliant -Finding $finding

        $detail = [string](Get-PropertyValue -Obj $finding -Names @('Detail', 'detail', 'Description', 'description') -Default '')
        $remediation = [string](Get-PropertyValue -Obj $finding -Names @('Remediation', 'remediation', 'remediation_doc') -Default (Get-PropertyValue -Obj $tags -Names @('remediation_doc') -Default ''))
        $learnMore = [string](Get-PropertyValue -Obj $finding -Names @('LearnMoreUrl', 'learnMoreUrl', 'DocumentationUrl', 'documentation_url') -Default '')
        $deepLink = [string](Get-PropertyValue -Obj $finding -Names @('DeepLinkUrl', 'deepLinkUrl') -Default (Get-PropertyValue -Obj $tags -Names @('deep_link_url', 'documentation_url') -Default $learnMore))

        $frameworks = Resolve-Frameworks -Finding $finding -Tags $tags
        $evidenceUris = @(
            (Get-StringArray -Value (Get-PropertyValue -Obj $finding -Names @('EvidenceUris', 'evidenceUris') -Default @())) +
            (Get-StringArray -Value (Get-PropertyValue -Obj $tags -Names @('evidence_uri', 'evidence_uris') -Default @()))
        ) | Where-Object { $_ } | Select-Object -Unique

        $baselineTags = @(
            (Get-StringArray -Value (Get-PropertyValue -Obj $finding -Names @('BaselineTags', 'baselineTags') -Default @())) +
            (Get-StringArray -Value (Get-PropertyValue -Obj $tags -Names @('baseline_tags') -Default @()))
        )
        $baseline = [string](Get-PropertyValue -Obj $tags -Names @('baseline') -Default '')
        if ($baseline) { $baselineTags += "baseline:$baseline" }
        $release = [string](Get-PropertyValue -Obj $tags -Names @('release') -Default '')
        if ($release) { $baselineTags += "release:$release" }
        $baselineTags = @($baselineTags | Where-Object { $_ } | Select-Object -Unique)

        $snippetText = [string](Get-PropertyValue -Obj $finding -Names @('RemediationDoc', 'remediation_doc') -Default (Get-PropertyValue -Obj $tags -Names @('remediation_doc') -Default ''))
        $snippets = @()
        if ($snippetText) {
            $snippets = @(@{ title = 'Powerpipe remediation'; content = $snippetText; language = 'text' })
        }

        $mitreTactics = @(
            (Get-StringArray -Value (Get-PropertyValue -Obj $finding -Names @('MitreTactics', 'mitreTactics') -Default @())) +
            (Get-StringArray -Value (Get-PropertyValue -Obj $tags -Names @('mitre_tactics') -Default @()))
        ) | Where-Object { $_ } | Select-Object -Unique
        $mitreTechniques = @(
            (Get-StringArray -Value (Get-PropertyValue -Obj $finding -Names @('MitreTechniques', 'mitreTechniques') -Default @())) +
            (Get-StringArray -Value (Get-PropertyValue -Obj $tags -Names @('mitre_techniques') -Default @()))
        ) | Where-Object { $_ } | Select-Object -Unique

        $findingVersion = [string](Get-PropertyValue -Obj $finding -Names @('ToolVersion', 'toolVersion') -Default $toolVersion)
        $pillarRaw = [string](Get-PropertyValue -Obj $finding -Names @('Pillar', 'pillar') -Default (Get-PropertyValue -Obj $tags -Names @('pillar') -Default $category))

        $row = New-FindingRow -Id ([string](Get-PropertyValue -Obj $finding -Names @('Id', 'id') -Default ([guid]::NewGuid().ToString()))) `
            -Source 'powerpipe' -EntityId $canonicalId -EntityType 'AzureResource' `
            -RuleId $controlId -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Frameworks $frameworks `
            -Pillar (Resolve-Pillar -Raw $pillarRaw) `
            -Impact ([string](Get-PropertyValue -Obj $finding -Names @('Impact', 'impact') -Default (Get-PropertyValue -Obj $tags -Names @('impact') -Default ''))) `
            -Effort ([string](Get-PropertyValue -Obj $finding -Names @('Effort', 'effort') -Default (Get-PropertyValue -Obj $tags -Names @('effort') -Default ''))) `
            -DeepLinkUrl $deepLink `
            -RemediationSnippets @($snippets) `
            -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags `
            -MitreTactics $mitreTactics `
            -MitreTechniques $mitreTechniques `
            -EntityRefs (Get-StringArray -Value (Get-PropertyValue -Obj $finding -Names @('EntityRefs', 'entityRefs') -Default @())) `
            -ToolVersion $findingVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
