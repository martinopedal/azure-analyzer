#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Bicep IaC validation findings.
.DESCRIPTION
    Converts raw Bicep wrapper output to v2 FindingRow objects.
    Platform=GitHub, EntityType=Repository.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Convert-ToBicepPathSlug {
    param ([string] $PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
    return ($PathValue.Trim() -replace '\\', '/' -replace '^\./', '').ToLowerInvariant()
}

function Resolve-BicepRuleId {
    param ([object] $Finding)
    if ($Finding.PSObject.Properties['RuleId'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.RuleId)) {
        return [string]$Finding.RuleId
    }

    $detail = ''
    if ($Finding.PSObject.Properties['Detail'] -and $null -ne $Finding.Detail) { $detail = [string]$Finding.Detail }
    $match = [regex]::Match($detail, '\b(BCP\d{3}|AZR-[A-Z0-9-]+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups[1].Value.ToUpperInvariant() }
    return 'BICEP-UNKNOWN'
}

function Resolve-BicepLevel {
    param ([object] $Finding)
    if ($Finding.PSObject.Properties['Level'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Level)) {
        return [string]$Finding.Level
    }

    $detail = ''
    if ($Finding.PSObject.Properties['Detail'] -and $null -ne $Finding.Detail) { $detail = [string]$Finding.Detail }
    if ($detail -match '(?i)\berror\b') { return 'Error' }
    if ($detail -match '(?i)\bwarning\b') { return 'Warning' }
    if ($detail -match '(?i)\binfo(?:rmational)?\b') { return 'Info' }
    return ''
}

function Resolve-BicepSeverity {
    param ([string] $RawSeverity, [string] $Level)
    $sev = if (-not [string]::IsNullOrWhiteSpace($Level)) { $Level } else { $RawSeverity }
    switch -Regex ($sev.ToLowerInvariant()) {
        'critical'         { 'Critical' }
        '^error$|high'     { 'High' }
        '^warning$|medium|moderate' { 'Medium' }
        '^info$|informational|low' { 'Low' }
        default            { 'Info' }
    }
}

function Resolve-BicepPillar {
    param (
        [string] $RuleId,
        [string] $Category,
        [string] $Title,
        [string] $Detail
    )

    $haystack = "$RuleId $Category $Title $Detail".ToLowerInvariant()
    if ($haystack -match 'cost|sku|pricing|budget|reserved|retention|size') { return 'Cost Optimization' }
    if ($haystack -match 'performance|throughput|latency|cache|concurrency') { return 'Performance Efficiency' }
    if ($haystack -match 'reliability|availability|zone|backup|dr|failover|region') { return 'Reliability' }
    if ($haystack -match 'operation|operational|diagnostic|logging|monitor|tag|governance|policy') { return 'Operational Excellence' }
    if ($haystack -match 'security|secret|password|keyvault|identity|rbac|tls|encrypt|defender') { return 'Security' }
    return 'Security'
}

function Resolve-BicepImpact {
    param ([string] $Severity)
    switch ($Severity) {
        'Critical' { 'High' }
        'High' { 'High' }
        'Medium' { 'Medium' }
        'Low' { 'Low' }
        default { 'Low' }
    }
}

function Resolve-BicepFrameworks {
    param ([string] $Pillar)
    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    $frameworks.Add(@{ kind = 'Azure WAF'; controlId = $Pillar }) | Out-Null
    switch ($Pillar) {
        'Security' {
            $frameworks.Add(@{ kind = 'CIS Azure'; controlId = '3.1' }) | Out-Null
            $frameworks.Add(@{ kind = 'Azure Security Benchmark'; controlId = 'NS-1' }) | Out-Null
        }
        'Reliability' {
            $frameworks.Add(@{ kind = 'CIS Azure'; controlId = '4.1' }) | Out-Null
            $frameworks.Add(@{ kind = 'Azure Security Benchmark'; controlId = 'RE-1' }) | Out-Null
        }
        'Cost Optimization' {
            $frameworks.Add(@{ kind = 'CIS Azure'; controlId = '5.1' }) | Out-Null
            $frameworks.Add(@{ kind = 'Azure Security Benchmark'; controlId = 'PV-5' }) | Out-Null
        }
        'Performance Efficiency' {
            $frameworks.Add(@{ kind = 'CIS Azure'; controlId = '6.1' }) | Out-Null
            $frameworks.Add(@{ kind = 'Azure Security Benchmark'; controlId = 'PE-1' }) | Out-Null
        }
        'Operational Excellence' {
            $frameworks.Add(@{ kind = 'CIS Azure'; controlId = '2.1' }) | Out-Null
            $frameworks.Add(@{ kind = 'Azure Security Benchmark'; controlId = 'OE-1' }) | Out-Null
        }
    }
    return @($frameworks)
}

function Resolve-BicepDeepLinkUrl {
    param (
        [string] $RuleId,
        [string] $LearnMoreUrl
    )

    if ($RuleId -match '^[a-z][a-z0-9\-]+$') {
        return "https://learn.microsoft.com/azure/azure-resource-manager/bicep/linter-rule-$($RuleId.ToLowerInvariant())"
    }
    if ($RuleId -match '^AZR-[A-Z0-9-]+$') {
        return "https://azure.github.io/PSRule.Rules.Azure/en/rules/$RuleId/"
    }
    if (-not [string]::IsNullOrWhiteSpace($LearnMoreUrl)) { return $LearnMoreUrl }
    return 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/linter'
}

function Resolve-BicepEvidenceUris {
    param (
        [string] $PathSlug,
        [string] $Detail,
        [string] $RepositoryUrl,
        [string] $RepositoryRef
    )

    $lineAnchor = ''
    $lineMatch = [regex]::Match($Detail, '\((?<line>\d+)(?:,\d+)?\)')
    if ($lineMatch.Success) { $lineAnchor = "#L$($lineMatch.Groups['line'].Value)" }

    $uris = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($PathSlug)) {
        $uris.Add("file:///$PathSlug$lineAnchor") | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($RepositoryUrl)) {
            $ref = if ([string]::IsNullOrWhiteSpace($RepositoryRef)) { 'main' } else { $RepositoryRef }
            $repo = $RepositoryUrl.TrimEnd('/')
            $uris.Add("$repo/blob/$ref/$PathSlug$lineAnchor") | Out-Null
        }
    }
    return @($uris)
}

function Resolve-BicepRemediationSnippets {
    param (
        [string] $RuleId,
        [string] $Remediation
    )

    $after = if ([string]::IsNullOrWhiteSpace($Remediation)) { '// apply recommended Bicep fix' } else { $Remediation.Trim() }
    return @(
        @{
            language = 'bicep'
            before   = "// noncompliant: $RuleId"
            after    = "// compliant: $after"
        }
    )
}

function Resolve-BicepScoreDelta {
    param ([string] $Severity)
    switch ($Severity) {
        'Critical' { return [double]4.0 }
        'High' { return [double]3.0 }
        'Medium' { return [double]2.0 }
        'Low' { return [double]1.0 }
        default { return [double]0.0 }
    }
}

function Normalize-IaCBicep {
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

        $pathSlug = Convert-ToBicepPathSlug -PathValue $rawId
        $canonicalId = ''
        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($pathSlug)) {
            $slugToken = $pathSlug -replace '[^a-z0-9/\-]', '-' -replace '/', '-'
            $syntheticArmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/iac-bicep/providers/Microsoft.Resources/deployments/$slugToken"
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $syntheticArmId -EntityType 'AzureResource').CanonicalId
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }
        if (-not $canonicalId) {
            $fallbackArmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/iac-bicep/providers/Microsoft.Resources/deployments/$findingId"
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $fallbackArmId -EntityType 'AzureResource').CanonicalId
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'IaC Validation' }

        $level = Resolve-BicepLevel -Finding $finding
        $rawSev = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { [string]$finding.Severity } else { 'Info' }
        $severity = Resolve-BicepSeverity -RawSeverity $rawSev -Level $level

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $false }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { $finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { $finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { $finding.LearnMoreUrl } else { '' }
        $ruleId = Resolve-BicepRuleId -Finding $finding
        $pillar = Resolve-BicepPillar -RuleId $ruleId -Category ([string]$category) -Title ([string]$title) -Detail ([string]$detail)
        $impact = Resolve-BicepImpact -Severity $severity
        $frameworks = Resolve-BicepFrameworks -Pillar $pillar
        $deepLinkUrl = Resolve-BicepDeepLinkUrl -RuleId $ruleId -LearnMoreUrl $learnMore
        $baselineLevel = if ([string]::IsNullOrWhiteSpace($level)) { $severity } else { $level }
        $baselineTags = @(
            "bicep:rule:$ruleId",
            "bicep:level:$baselineLevel",
            "bicep:category:$category"
        )
        $repositoryUrl = if ($ToolResult.PSObject.Properties['RepositoryUrl'] -and $ToolResult.RepositoryUrl) { [string]$ToolResult.RepositoryUrl } else { '' }
        $repositoryRef = if ($ToolResult.PSObject.Properties['RepositoryRef'] -and $ToolResult.RepositoryRef) { [string]$ToolResult.RepositoryRef } else { 'main' }
        $evidenceUris = Resolve-BicepEvidenceUris -PathSlug $pathSlug -Detail ([string]$detail) -RepositoryUrl $repositoryUrl -RepositoryRef $repositoryRef
        $entityRefs = @("iac:bicep:$pathSlug")
        if (-not [string]::IsNullOrWhiteSpace($pathSlug)) {
            $pathDir = Split-Path -Path $pathSlug -Parent
            if (-not [string]::IsNullOrWhiteSpace($pathDir)) { $entityRefs += "iac:module:$pathDir" }
        }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) {
            [string]$finding.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) {
            [string]$ToolResult.ToolVersion
        } else {
            ''
        }
        $remediationSnippets = Resolve-BicepRemediationSnippets -RuleId $ruleId -Remediation ([string]$remediation)
        $scoreDelta = Resolve-BicepScoreDelta -Severity $severity

        $row = New-FindingRow -Id $findingId `
            -Source 'bicep-iac' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') -RuleId $ruleId `
            -Pillar $pillar -Impact $impact -Effort 'Low' -DeepLinkUrl $deepLinkUrl `
            -Frameworks $frameworks -RemediationSnippets $remediationSnippets `
            -EvidenceUris $evidenceUris -BaselineTags $baselineTags `
            -ScoreDelta $scoreDelta -EntityRefs $entityRefs -ToolVersion $toolVersion
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
