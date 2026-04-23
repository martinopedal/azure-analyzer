#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for ADO pipeline security findings.
.DESCRIPTION
    Converts raw ADO pipeline security wrapper output into v2 FindingRow objects.
    Uses first-class ADO entity types for pipelines, variable groups, environments,
    and service connections when the wrapper provides that asset metadata.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-ADOPipelineSecurity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult,
        [System.Collections.Generic.List[psobject]] $EdgeCollector
    )

    if ($ToolResult.Status -notin @('Success', 'PartialSuccess') -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Add-ADOPipelineTrackAEdges {
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
            $edge = New-Edge -Source $source -Target $target -Relation $relation -Confidence 'Likely' -Platform 'ADO' -DiscoveredBy 'ado-pipelines'
            if ($null -ne $edge) { $EdgeCollector.Add($edge) | Out-Null }
        }
    }

    function ConvertTo-StringArray {
        param ([object] $Value)
        if ($null -eq $Value) { return @() }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
            return @($Value.Trim())
        }
        if ($Value -is [System.Collections.IEnumerable]) {
            return @($Value | ForEach-Object {
                    if ($null -eq $_) { return }
                    $candidate = [string]$_
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $candidate.Trim() }
                } | Select-Object -Unique)
        }
        return @([string]$Value)
    }

    function ConvertTo-Snippets {
        param ([object] $Value)
        if ($null -eq $Value) { return @() }
        $snippets = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($snippet in @($Value)) {
            if ($null -eq $snippet) { continue }
            $language = if ($snippet.PSObject.Properties['language'] -and $snippet.language) { [string]$snippet.language } else { 'bash' }
            $content = if ($snippet.PSObject.Properties['content'] -and $snippet.content) { [string]$snippet.content } elseif ($snippet.PSObject.Properties['code'] -and $snippet.code) { [string]$snippet.code } else { '' }
            if ([string]::IsNullOrWhiteSpace($content)) { continue }
            $snippets.Add(@{
                    language = $language.Trim().ToLowerInvariant()
                    content  = $content.Trim()
                }) | Out-Null
        }
        return @($snippets)
    }

    function Get-ControlTagFromRuleId {
        param ([string] $RuleId)
        if ([string]::IsNullOrWhiteSpace($RuleId)) { return '' }
        if ($RuleId -match '^(Approval-Missing)') { return 'Approval-Missing' }
        if ($RuleId -match '^(Approval-Present)') { return 'Approval-Present' }
        if ($RuleId -match '^(Approval-Verification)') { return 'Approval-Verification' }
        if ($RuleId -match '^(Branch-Unprotected)') { return 'Branch-Unprotected' }
        if ($RuleId -match '^(Secret-InVariable)') { return 'Secret-InVariable' }
        if ($RuleId -match '^(SecretStore-KeyVault-Missing)') { return 'SecretStore-KeyVault-Missing' }
        if ($RuleId -match '^(ServiceConnection-OverReuse)') { return 'ServiceConnection-OverReuse' }
        return $RuleId
    }

    foreach ($finding in $ToolResult.Findings) {
        Add-ADOPipelineTrackAEdges -Candidate $finding
        $assetType = if ($finding.PSObject.Properties['AssetType'] -and $finding.AssetType) { [string]$finding.AssetType } else { 'BuildDefinition' }
        $entityType = $assetType
        $org = if ($finding.PSObject.Properties['AdoOrg'] -and $finding.AdoOrg) { [string]$finding.AdoOrg } else { 'unknown' }
        $project = if ($finding.PSObject.Properties['AdoProject'] -and $finding.AdoProject) { [string]$finding.AdoProject } else { 'unknown' }
        $assetId = if ($finding.PSObject.Properties['AssetId'] -and $finding.AssetId) { [string]$finding.AssetId } else { '' }
        if ([string]::IsNullOrWhiteSpace($assetId)) {
            $assetId = if ($finding.PSObject.Properties['AssetName'] -and $finding.AssetName) { [string]$finding.AssetName } else { [guid]::NewGuid().ToString() }
        }
        $canonicalId = "$org/$project/$assetType/$assetId".ToLowerInvariant()

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $severity = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) {
            switch -Regex ([string]$finding.Severity) {
                '^(?i)critical$' { 'Critical' }
                '^(?i)high$'     { 'High' }
                '^(?i)medium$'   { 'Medium' }
                '^(?i)low$'      { 'Low' }
                '^(?i)info'      { 'Info' }
                default          { 'Info' }
            }
        } else {
            'Info'
        }

        $resourceId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) { [string]$finding.ResourceId } else { '' }
        $ruleId = if ($finding.PSObject.Properties['RuleId'] -and $finding.RuleId) { [string]$finding.RuleId } else { '' }
        $baselineTags = [System.Collections.Generic.List[string]]::new()
        $baselineTags.Add("Asset-$assetType") | Out-Null
        $controlTag = Get-ControlTagFromRuleId -RuleId $ruleId
        if (-not [string]::IsNullOrWhiteSpace($controlTag)) {
            $baselineTags.Add($controlTag) | Out-Null
        }
        $entityRefs = ConvertTo-StringArray -Value $(if ($finding.PSObject.Properties['EntityRefs']) { $finding.EntityRefs } else { @() })
        $evidenceUris = ConvertTo-StringArray -Value $(if ($finding.PSObject.Properties['EvidenceUris']) { $finding.EvidenceUris } else { @() })
        $remediationSnippets = ConvertTo-Snippets -Value $(if ($finding.PSObject.Properties['RemediationSnippets']) { $finding.RemediationSnippets } else { @() })
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } else { 'unknown' }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Security' }
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else { '' }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else { '' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'ado-pipelines' -EntityId $canonicalId -EntityType $entityType `
            -Title ([string]$finding.Title) -RuleId $ruleId -Compliant ([bool]$finding.Compliant) -ProvenanceRunId $runId `
            -Platform 'AzureDevOps' -Category ([string]$finding.Category) -Severity $severity `
            -Detail ([string]$finding.Detail) -Remediation ([string]$finding.Remediation) `
            -LearnMoreUrl ([string]$finding.LearnMoreUrl) -ResourceId $resourceId `
            -Pillar $pillar -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets $remediationSnippets -EvidenceUris $evidenceUris `
            -Frameworks @() -MitreTactics @() -MitreTechniques @() `
            -BaselineTags @($baselineTags | Select-Object -Unique) -EntityRefs $entityRefs `
            -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
