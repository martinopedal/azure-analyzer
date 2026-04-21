#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Terraform IaC validation findings.
.DESCRIPTION
    Converts raw Terraform wrapper output to v2.2 FindingRow objects.
    Platform=Azure with EntityType=AzureResource or IaCFile.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"
. "$PSScriptRoot\..\shared\EntityStore.ps1"

function Convert-ToStringArray {
    param ([object]$Value)
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) { $items.Add($text.Trim()) | Out-Null }
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
        $props = @()
        if ($entry.PSObject) { $props = @($entry.PSObject.Properties) }
        if ($props.Count -gt 0) {
            $map = @{}
            foreach ($prop in $props) { $map[$prop.Name] = $prop.Value }
            $items.Add($map) | Out-Null
        }
    }
    return @($items)
}

function Resolve-TerraformRuleId {
    param([object]$Finding)
    if ($Finding.PSObject.Properties['RuleId'] -and $Finding.RuleId) { return [string]$Finding.RuleId }
    if ($Finding.PSObject.Properties['Id'] -and $Finding.Id) { return [string]$Finding.Id }
    if ($Finding.PSObject.Properties['Title'] -and $Finding.Title -and [string]$Finding.Title -match '^(AVD-[A-Z]+-\d+|CKV_[A-Z_0-9]+|TFSEC-[A-Z_0-9-]+)') { return $Matches[1] }
    return 'terraform-validate'
}

function Resolve-TerraformIaCEntity {
    param([object]$Finding)
    $armCandidate = ''
    if ($Finding.PSObject.Properties['ArmResourceId'] -and $Finding.ArmResourceId) { $armCandidate = [string]$Finding.ArmResourceId }
    if (-not $armCandidate -and $Finding.PSObject.Properties['ResourceAddress'] -and $Finding.ResourceAddress -and [string]$Finding.ResourceAddress -match '^/subscriptions/') {
        $armCandidate = [string]$Finding.ResourceAddress
    }
    if ($armCandidate -and $armCandidate -match '^/subscriptions/') {
        try {
            return @{
                EntityType = 'AzureResource'
                EntityId   = (ConvertTo-CanonicalEntityId -RawId $armCandidate -EntityType 'AzureResource').CanonicalId
            }
        } catch { }
    }

    $path = ''
    $resourceAddress = if ($Finding.PSObject.Properties['ResourceAddress'] -and $Finding.ResourceAddress) { [string]$Finding.ResourceAddress } else { '' }
    foreach ($uri in @(Convert-ToStringArray $Finding.EvidenceUris)) {
        if ($uri -match '^file://([^#]+)') { $path = $Matches[1]; break }
        if ($uri -match '/blob/[^/]+/(.+?)(?:#L\d+)?$') { $path = $Matches[1]; break }
    }
    if (-not $path) {
        $raw = if ($Finding.PSObject.Properties['ResourceId'] -and $Finding.ResourceId) { [string]$Finding.ResourceId } else { 'main.tf' }
        $path = ($raw -replace '\\', '/') -replace '^\./', ''
        if (-not $path.EndsWith('.tf')) { $path = "$path/main.tf" }
    }
    $id = "iac:terraform:$($path.ToLowerInvariant())"
    if (-not [string]::IsNullOrWhiteSpace($resourceAddress)) {
        $id = "$id#$($resourceAddress.ToLowerInvariant())"
    }
    return @{ EntityType = 'IaCFile'; EntityId = $id }
}

function Normalize-IaCTerraform {
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
        $rawId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) { [string]$finding.ResourceId } else { '' }
        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) { [string]$finding.Id } else { [guid]::NewGuid().ToString() }
        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { [string]$finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { [string]$finding.Category } else { 'IaC Validation' }
        $ruleId = Resolve-TerraformRuleId -Finding $finding

        $rawSev = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { [string]$finding.Severity } else { 'medium' }
        $severity = switch -Regex ($rawSev.ToLowerInvariant()) {
            'critical' { 'Critical' }
            'high' { 'High' }
            'medium|moderate' { 'Medium' }
            'low' { 'Low' }
            'info|unknown' { 'Info' }
            default { 'Info' }
        }

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $false }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { [string]$finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { [string]$finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { [string]$finding.LearnMoreUrl } else { '' }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Security' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { $learnMore }
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else { '' }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else { '' }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) { [string]$finding.ToolVersion } elseif ($ToolResult.PSObject.Properties['ToolVersion']) { [string]$ToolResult.ToolVersion } else { '' }

        $rawFrameworks = if ($finding.PSObject.Properties['Frameworks']) { $finding.Frameworks } else { @() }
        $frameworks = Merge-FrameworksUnion -Existing @() -Incoming @(Convert-ToHashtableArray $rawFrameworks)
        $rawBaselineTags = if ($finding.PSObject.Properties['BaselineTags']) { $finding.BaselineTags } else { @() }
        $baselineTags = Merge-BaselineTagsUnion -Existing @() -Incoming @(Convert-ToStringArray $rawBaselineTags)
        if (@($baselineTags).Count -eq 0) {
            $toolLabel = 'trivy'
            if ($ruleId -eq 'terraform-validate' -or $ruleId -eq 'terraform-init') { $toolLabel = 'terraform' }
            $baselineTags = @("terraform:rule:$($ruleId.ToLowerInvariant())", 'terraform:provider:azurerm', "terraform:tool:$toolLabel")
        }

        $rawEvidenceUris = if ($finding.PSObject.Properties['EvidenceUris']) { $finding.EvidenceUris } else { @() }
        $evidenceUris = Convert-ToStringArray $rawEvidenceUris
        $rawEntityRefs = if ($finding.PSObject.Properties['EntityRefs']) { $finding.EntityRefs } else { @() }
        $entityRefs = Convert-ToStringArray $rawEntityRefs
        $resourceAddress = if ($finding.PSObject.Properties['ResourceAddress'] -and $finding.ResourceAddress) { [string]$finding.ResourceAddress } else { '' }
        $entity = Resolve-TerraformIaCEntity -Finding $finding

        if (@($entityRefs).Count -eq 0 -and $entity.EntityType -eq 'IaCFile') {
            $entityRefs = @($entity.EntityId)
            if (-not [string]::IsNullOrWhiteSpace($resourceAddress)) {
                $baseEntityId = $entity.EntityId.Split('#')[0]
                $resourceRef = "$baseEntityId#$($resourceAddress.ToLowerInvariant())"
                if ($entityRefs -notcontains $resourceRef) {
                    $entityRefs += $resourceRef
                }
            }
        }

        $rawSnippets = if ($finding.PSObject.Properties['RemediationSnippets']) { $finding.RemediationSnippets } else { @() }
        $snippets = Convert-ToHashtableArray $rawSnippets
        if (@($snippets).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($remediation)) {
            $snippets = @(@{ language = 'hcl'; code = "- # existing configuration`n+ # remediation: $remediation" })
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'terraform-iac' -EntityId $entity.EntityId -EntityType $entity.EntityType `
            -Title $title -RuleId $ruleId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -Frameworks $frameworks -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets $snippets `
            -EvidenceUris $evidenceUris -BaselineTags $baselineTags `
            -EntityRefs $entityRefs -ToolVersion $toolVersion
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
