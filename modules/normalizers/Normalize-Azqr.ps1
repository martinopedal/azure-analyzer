#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Azure Quick Review (azqr) findings.
.DESCRIPTION
    Converts raw azqr wrapper output to v3 FindingRow objects.
    Platform=Azure, EntityType=AzureResource.
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

function Resolve-Pillar {
    param ([object]$Finding)

    $rawPillar = [string](Get-PropertyValue $Finding 'Pillar' '')
    if (-not [string]::IsNullOrWhiteSpace($rawPillar)) { return $rawPillar.Trim() }

    $category = [string](Get-PropertyValue $Finding 'Category' (Get-PropertyValue $Finding 'ServiceCategory' ''))
    switch -Regex ($category.Trim().ToLowerInvariant()) {
        'security|identity|networking|encryption' { return 'Security' }
        'reliability|highavailability|high availability|businesscontinuity' { return 'Reliability' }
        'cost|finops' { return 'CostOptimization' }
        'performance' { return 'PerformanceEfficiency' }
        'monitoring|monitoringandalerting|operational|operations|operationalexcellence' { return 'OperationalExcellence' }
        default { return '' }
    }
}

function Resolve-Frameworks {
    param (
        [object]$Finding,
        [string]$Pillar
    )

    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($fw in @(Get-PropertyValue $Finding 'Frameworks' @())) {
        if ($fw -is [System.Collections.IDictionary]) {
            $kind = [string]($fw['kind'] ?? $fw['Kind'] ?? '')
            $controlId = [string]($fw['controlId'] ?? $fw['ControlId'] ?? '')
            if (-not [string]::IsNullOrWhiteSpace($kind) -and -not [string]::IsNullOrWhiteSpace($controlId)) {
                $frameworks.Add(@{ kind = $kind.Trim(); controlId = $controlId.Trim() }) | Out-Null
                continue
            }

            $name = [string]($fw['Name'] ?? $fw['name'] ?? '')
            foreach ($control in @(Convert-ToStringArray ($fw['Controls'] ?? $fw['controls'] ?? @()))) {
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $frameworks.Add(@{ kind = $name.Trim(); controlId = $control }) | Out-Null
                }
            }
        } elseif ($fw.PSObject -and $fw.PSObject.Properties['kind']) {
            $kind = [string]$fw.kind
            $controlId = [string](Get-PropertyValue $fw 'controlId' (Get-PropertyValue $fw 'ControlId' ''))
            if (-not [string]::IsNullOrWhiteSpace($kind) -and -not [string]::IsNullOrWhiteSpace($controlId)) {
                $frameworks.Add(@{ kind = $kind.Trim(); controlId = $controlId.Trim() }) | Out-Null
            }
        } elseif ($fw) {
            $text = [string]$fw
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $frameworks.Add(@{ kind = 'WAF'; controlId = $text.Trim() }) | Out-Null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Pillar)) {
        $frameworks.Add(@{ kind = 'WAF'; controlId = $Pillar }) | Out-Null
    }

    return @($frameworks)
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
        if ($entry.PSObject) {
            $props = @($entry.PSObject.Properties)
        }
        if ($props.Count -gt 0) {
            $map = @{}
            foreach ($prop in $props) { $map[$prop.Name] = $prop.Value }
            $items.Add($map) | Out-Null
            continue
        }

        $text = [string]$entry
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $items.Add(@{ code = $text.Trim() }) | Out-Null
        }
    }
    return @($items)
}

function Normalize-Azqr {
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
        $rawId = Get-PropertyValue $finding 'ResourceId' (Get-PropertyValue $finding 'Id' '')
        $subId = ''
        $rg = ''
        $canonicalId = ''
        $findingId = Get-PropertyValue $finding 'Id' ([guid]::NewGuid().ToString())

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalMeta = ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource'
                $canonicalId = $canonicalMeta.CanonicalId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '(?i)/subscriptions/([^/]+)') { $subId = $Matches[1].ToLowerInvariant() }
            if ($rawId -match '(?i)/resourcegroups/([^/]+)') { $rg = $Matches[1] }
        }

        # Synthesize entity ID when no ARM ID is available
        if (-not $canonicalId) {
            $fallbackSub = if ($subId -match '^[0-9a-fA-F-]{36}$') {
                $subId.ToLowerInvariant()
            } else {
                '00000000-0000-0000-0000-000000000000'
            }
            $fallbackArmId = "/subscriptions/$fallbackSub/providers/microsoft.resourcegraph/azqrfindings/$findingId"
            $canonicalMeta = ConvertTo-CanonicalEntityId -RawId $fallbackArmId -EntityType 'AzureResource'
            $canonicalId = $canonicalMeta.CanonicalId
        }

        $title = Get-PropertyValue $finding 'Recommendation' (Get-PropertyValue $finding 'Title' (Get-PropertyValue $finding 'Description' 'Unknown'))
        $category = Get-PropertyValue $finding 'Category' (Get-PropertyValue $finding 'ServiceCategory' 'General')

        # Map severity from raw azqr values
        $rawSev = Get-PropertyValue $finding 'Severity' (Get-PropertyValue $finding 'Risk' 'Info')
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            'info'             { 'Info' }
            default            { 'Medium' }
        }

        # Determine compliance: azqr uses Result=OK or Compliant=$true
        $resultVal = Get-PropertyValue $finding 'Result' ''
        $compliantVal = Get-PropertyValue $finding 'Compliant' $null
        $compliant = ($resultVal -eq 'OK') -or ($compliantVal -eq $true)

        $detail = Get-PropertyValue $finding 'Notes' (Get-PropertyValue $finding 'Detail' (Get-PropertyValue $finding 'Description' ''))
        $remediation = Get-PropertyValue $finding 'Remediation' (Get-PropertyValue $finding 'Url' '')
        $learnMore = Get-PropertyValue $finding 'LearnMoreLink' (Get-PropertyValue $finding 'LearnMoreUrl' (Get-PropertyValue $finding 'Url' ''))
        $ruleId = [string](Get-PropertyValue $finding 'RecommendationId' (Get-PropertyValue $finding 'RuleId' ''))
        $pillar = Resolve-Pillar -Finding $finding
        $frameworks = Resolve-Frameworks -Finding $finding -Pillar $pillar
        $impact = [string](Get-PropertyValue $finding 'Impact' '')
        $effort = [string](Get-PropertyValue $finding 'Effort' '')
        $deepLinkUrl = [string](Get-PropertyValue $finding 'DeepLinkUrl' (Get-PropertyValue $finding 'PortalUrl' ''))
        $remediationSnippets = @(Convert-ToHashtableArray (Get-PropertyValue $finding 'RemediationSnippets' @()))
        $evidenceUris = @(Convert-ToStringArray (Get-PropertyValue $finding 'EvidenceUris' @()))
        $baselineTags = @(Convert-ToStringArray (Get-PropertyValue $finding 'BaselineTags' @()))
        $mitreTactics = @(Convert-ToStringArray (Get-PropertyValue $finding 'MitreTactics' (Get-PropertyValue $finding 'Tactics' @())))
        $mitreTechniques = @(Convert-ToStringArray (Get-PropertyValue $finding 'MitreTechniques' (Get-PropertyValue $finding 'Techniques' @())))
        $entityRefs = @(Convert-ToStringArray (Get-PropertyValue $finding 'EntityRefs' @()))
        $toolVersion = [string](Get-PropertyValue $finding 'ToolVersion' (Get-PropertyValue $ToolResult 'ToolVersion' ''))

        $row = New-FindingRow -Id ([guid]::NewGuid().ToString()) `
            -Source 'azqr' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg `
            -RuleId $ruleId -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -Frameworks $frameworks `
            -RemediationSnippets $remediationSnippets -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags -MitreTactics $mitreTactics `
            -MitreTechniques $mitreTechniques -EntityRefs $entityRefs `
            -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
