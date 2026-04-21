#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Terraform IaC validation findings.
.DESCRIPTION
    Converts raw Terraform wrapper output to v2.2 FindingRow objects.
    Platform=GitHub with EntityType=Repository.
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

function Resolve-TerraformRepositoryEntityId {
    param([object]$ToolResult)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($ToolResult.PSObject.Properties['Repository'] -and $ToolResult.Repository) { $candidates.Add([string]$ToolResult.Repository) | Out-Null }
    if ($ToolResult.PSObject.Properties['RemoteUrl'] -and $ToolResult.RemoteUrl) { $candidates.Add([string]$ToolResult.RemoteUrl) | Out-Null }
    if ($ToolResult.PSObject.Properties['SourceRepoUrl'] -and $ToolResult.SourceRepoUrl) { $candidates.Add([string]$ToolResult.SourceRepoUrl) | Out-Null }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try { return (ConvertTo-CanonicalEntityId -RawId $candidate -EntityType 'Repository').CanonicalId } catch { }
    }
    return 'iac.local/terraform-iac/repository'
}

function Resolve-TerraformMitreMapping {
    param (
        [string] $RuleId,
        [string] $Title,
        [string] $Detail,
        [string] $Category
    )

    $tactics = [System.Collections.Generic.List[string]]::new()
    $techniques = [System.Collections.Generic.List[string]]::new()

    if (-not ($Category -match '(?i)security')) {
        return @{
            MitreTactics = @()
            MitreTechniques = @()
        }
    }

    $signal = "$RuleId $Title $Detail".ToLowerInvariant()
    if ($signal -match 'identity|iam|role|permission|privilege|access') {
        $tactics.Add('TA0004') | Out-Null
        $techniques.Add('T1078') | Out-Null
    }
    if ($signal -match 'public|0\.0\.0\.0/0|ingress|network|nsg|firewall|exposed') {
        $tactics.Add('TA0001') | Out-Null
        $techniques.Add('T1190') | Out-Null
    }
    if ($signal -match 'keyvault|key vault|secret|token|credential|purge protection|encryption') {
        $tactics.Add('TA0006') | Out-Null
        $techniques.Add('T1552') | Out-Null
    }

    if ($tactics.Count -eq 0) {
        $tactics.Add('TA0001') | Out-Null
        $techniques.Add('T1190') | Out-Null
    }

    return @{
        MitreTactics = @($tactics | Select-Object -Unique)
        MitreTechniques = @($techniques | Select-Object -Unique)
    }
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
    $repositoryEntityId = Resolve-TerraformRepositoryEntityId -ToolResult $ToolResult
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
        $pillar = switch -Regex ($pillar.Trim()) {
            '^(?i)operations?|operational.?excellence$' { 'OperationalExcellence' }
            '^(?i)cost|costoptimization$' { 'CostOptimization' }
            '^(?i)performance|performanceefficiency$' { 'PerformanceEfficiency' }
            '^(?i)reliability$' { 'Reliability' }
            default { 'Security' }
        }
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
        if (@($entityRefs).Count -eq 0) {
            $path = ''
            foreach ($uri in @($evidenceUris)) {
                if ($uri -match '^file://([^#]+)') { $path = $Matches[1]; break }
                if ($uri -match '/blob/[^/]+/(.+?)(?:#L\d+)?$') { $path = $Matches[1]; break }
            }
            if (-not $path) {
                $path = (($rawId -replace '\\', '/') -replace '^\./', '').Trim()
                if ([string]::IsNullOrWhiteSpace($path)) { $path = 'main.tf' }
                if (-not $path.EndsWith('.tf')) { $path = "$path/main.tf" }
            }
            $entityRefs = @("iac:terraform:$($path.ToLowerInvariant())")
            if (-not [string]::IsNullOrWhiteSpace($resourceAddress)) {
                $entityRefs += "iac:terraform:$($path.ToLowerInvariant())#$($resourceAddress.ToLowerInvariant())"
            }
        }

        $mitre = Resolve-TerraformMitreMapping -RuleId $ruleId -Title $title -Detail $detail -Category $category

        $rawSnippets = if ($finding.PSObject.Properties['RemediationSnippets']) { $finding.RemediationSnippets } else { @() }
        $snippets = Convert-ToHashtableArray $rawSnippets
        if (@($snippets).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($remediation)) {
            $snippets = @(@{ language = 'hcl'; code = "- # existing configuration`n+ # remediation: $remediation" })
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'terraform-iac' -EntityId $repositoryEntityId -EntityType 'Repository' `
            -Title $title -RuleId $ruleId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'GitHub' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -Frameworks $frameworks -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets $snippets `
            -EvidenceUris $evidenceUris -BaselineTags $baselineTags `
            -MitreTactics $mitre.MitreTactics -MitreTechniques $mitre.MitreTechniques `
            -EntityRefs $entityRefs -ToolVersion $toolVersion
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
