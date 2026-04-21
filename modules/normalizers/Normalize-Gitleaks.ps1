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

function Get-PropertyValue {
    param ([object]$Obj, [string]$Name, [object]$Default = $null)
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
        if ($entry.PSObject) {
            $map = @{}
            foreach ($prop in @($entry.PSObject.Properties)) { $map[$prop.Name] = $prop.Value }
            if ($map.Count -gt 0) { $items.Add($map) | Out-Null }
        }
    }
    return @($items)
}

function Resolve-RepositoryEntityId {
    param (
        [object]$ToolResult
    )

    $candidate = [string](Get-PropertyValue -Obj $ToolResult -Name 'RepositoryEntityId' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        return $candidate.ToLowerInvariant()
    }

    $rawRepo = @(
        [string](Get-PropertyValue -Obj $ToolResult -Name 'RepositoryId' -Default ''),
        [string](Get-PropertyValue -Obj $ToolResult -Name 'RepositoryUrl' -Default ''),
        [string](Get-PropertyValue -Obj $ToolResult -Name 'Repository' -Default ''),
        [string](Get-PropertyValue -Obj $ToolResult -Name 'RemoteUrl' -Default '')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($rawRepo)) { return 'github.com/local/local' }
    $normalized = $rawRepo.Trim().ToLowerInvariant() -replace '\.git$', '' -replace '^https?://', '' -replace '^git@', '' -replace '^([^/:]+):', '$1/' -replace '^www\.', ''
    if ($normalized -match '^[^/]+/[^/]+/[^/]+$') { return $normalized }
    return 'github.com/local/local'
}

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
    $canonicalRepoId = Resolve-RepositoryEntityId -ToolResult $ToolResult

    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($finding in $ToolResult.Findings) {
        $rawId = [string](Get-PropertyValue -Obj $finding -Name 'ResourceId' -Default '')

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

        $title = [string](Get-PropertyValue -Obj $finding -Name 'Title' -Default 'Secret detected')
        $category = [string](Get-PropertyValue -Obj $finding -Name 'Category' -Default 'Secret Detection')

        $rawSev = [string](Get-PropertyValue -Obj $finding -Name 'Severity' -Default 'High')
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        $compliant = [bool](Get-PropertyValue -Obj $finding -Name 'Compliant' -Default $false)
        $detail = [string](Get-PropertyValue -Obj $finding -Name 'Detail' -Default '')
        $remediation = [string](Get-PropertyValue -Obj $finding -Name 'Remediation' -Default '')
        $learnMore = [string](Get-PropertyValue -Obj $finding -Name 'LearnMoreUrl' -Default '')
        $ruleId = [string](Get-PropertyValue -Obj $finding -Name 'RuleId' -Default '')
        $pillar = [string](Get-PropertyValue -Obj $finding -Name 'Pillar' -Default 'Security')
        $impact = [string](Get-PropertyValue -Obj $finding -Name 'Impact' -Default '')
        $effort = [string](Get-PropertyValue -Obj $finding -Name 'Effort' -Default '')
        $deepLinkUrl = [string](Get-PropertyValue -Obj $finding -Name 'DeepLinkUrl' -Default '')
        $frameworks = @(Convert-ToHashtableArray (Get-PropertyValue -Obj $finding -Name 'Frameworks' -Default @()))
        $remediationSnippets = @(Convert-ToHashtableArray (Get-PropertyValue -Obj $finding -Name 'RemediationSnippets' -Default @()))
        $evidenceUris = @(Convert-ToStringArray (Get-PropertyValue -Obj $finding -Name 'EvidenceUris' -Default @()))
        $baselineTags = @(Convert-ToStringArray (Get-PropertyValue -Obj $finding -Name 'BaselineTags' -Default @()))
        $entityRefs = @(Convert-ToStringArray (Get-PropertyValue -Obj $finding -Name 'EntityRefs' -Default @()))
        $toolVersion = [string](Get-PropertyValue -Obj $finding -Name 'ToolVersion' -Default (Get-PropertyValue -Obj $ToolResult -Name 'ToolVersion' -Default ''))

        $row = New-FindingRow -Id $findingId `
            -Source 'gitleaks' -EntityId $canonicalRepoId -EntityType 'Repository' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $canonicalPath `
            -RuleId $ruleId -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -Frameworks $frameworks `
            -RemediationSnippets $remediationSnippets -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags -EntityRefs $entityRefs -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
