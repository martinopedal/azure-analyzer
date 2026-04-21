#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for ALZ Resource Graph query findings.
.DESCRIPTION
    Converts raw alz-queries wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=AzureResource.
    ALZ findings have: Id, Title, Category, Severity, Compliant, Detail, ResourceId, LearnMoreUrl.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = '')
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

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

function Convert-ToTagSlug {
    param ([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $slug = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    return $slug.Trim('-')
}

function Resolve-Pillar {
    param (
        [string]$Category,
        [string]$Subcategory,
        [string]$Title
    )

    $seed = "$Category $Subcategory $Title".ToLowerInvariant()
    if ($seed -match 'identity|access|entra|rbac|mfa|pim|security|network|defender|key vault|firewall|ddos') {
        return 'Security'
    }
    return 'OperationalExcellence'
}

function Resolve-Impact {
    param ([string]$Severity)
    switch ($Severity) {
        'Critical' { return 'High' }
        'High' { return 'High' }
        'Medium' { return 'Medium' }
        'Low' { return 'Low' }
        default { return 'Low' }
    }
}

function Resolve-Effort {
    param ([string]$Severity)
    switch ($Severity) {
        'Critical' { return 'High' }
        'High' { return 'High' }
        'Medium' { return 'Medium' }
        default { return 'Low' }
    }
}

function Normalize-AlzQueries {
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

        # Use query GUID as fallback entity ID
        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $fallbackArmId = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/microsoft.resourcegraph/alzqueries/$findingId"
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $fallbackArmId -EntityType 'AzureResource').CanonicalId
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'ALZ' }
        $subcategory = [string](Get-PropertyValue $finding 'Subcategory' '')
        $severity = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { $finding.Severity } else { 'Medium' }

        # Validate severity is in the allowed set
        if ($severity -notin @('Critical', 'High', 'Medium', 'Low', 'Info')) {
            $severity = switch -Regex ($severity.ToString().ToLowerInvariant()) {
                'critical'         { 'Critical' }
                'high'             { 'High' }
                'medium|moderate'  { 'Medium' }
                'low'              { 'Low' }
                'info'             { 'Info' }
                default            { 'Medium' }
            }
        }

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $true }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { $finding.Detail } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { $finding.LearnMoreUrl } else { '' }
        $remediation = [string](Get-PropertyValue $finding 'Remediation' '')
        $pillar = Resolve-Pillar -Category $category -Subcategory $subcategory -Title ([string]$title)
        $impact = Resolve-Impact -Severity $severity
        $effort = Resolve-Effort -Severity $severity
        $deepLinkUrl = "https://github.com/martinopedal/alz-graph-queries/search?q=$findingId&type=code"
        $frameworks = @(@{ kind = 'ALZ'; controlId = $findingId })
        $baselineTags = [System.Collections.Generic.List[string]]::new()
        $categorySlug = Convert-ToTagSlug -Value $category
        if ($categorySlug) { $baselineTags.Add("alz-category:$categorySlug") | Out-Null }
        $subCategorySlug = Convert-ToTagSlug -Value $subcategory
        if ($subCategorySlug) { $baselineTags.Add("alz-subcategory:$subCategorySlug") | Out-Null }
        $evidenceUris = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($learnMore)) { $evidenceUris.Add($learnMore) | Out-Null }
        $evidenceUris.Add($deepLinkUrl) | Out-Null
        $entityRefs = [System.Collections.Generic.List[string]]::new()
        $entityRefs.Add([string]$canonicalId) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($rawId)) { $entityRefs.Add($rawId.ToLowerInvariant()) | Out-Null }
        $toolVersion = [string](Get-PropertyValue $finding 'ToolVersion' (Get-PropertyValue $ToolResult 'ToolVersion' ''))
        $remediationSnippets = @()
        if (-not [string]::IsNullOrWhiteSpace($remediation)) {
            $remediationSnippets = @(@{ language = 'text'; code = $remediation.Trim() })
        } elseif (-not [string]::IsNullOrWhiteSpace($detail)) {
            $remediationSnippets = @(@{ language = 'text'; code = $detail.Trim() })
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'alz-queries' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -RuleId $findingId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -Frameworks $frameworks `
            -RemediationSnippets $remediationSnippets -EvidenceUris @($evidenceUris) `
            -BaselineTags @($baselineTags) -EntityRefs @($entityRefs) `
            -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
