#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function ConvertTo-AksKarpenterSeverity {
    param([string]$RawSeverity)
    switch -Regex (($RawSeverity ?? '').ToLowerInvariant()) {
        '^critical$' { 'Critical' }
        '^high$'     { 'High' }
        '^medium$'   { 'Medium' }
        '^low$'      { 'Low' }
        '^info'      { 'Info' }
        default      { 'Info' }
    }
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
            foreach ($k in $entry.Keys) { $map[[string]$k] = $entry[$k] }
            $items.Add($map) | Out-Null
            continue
        }
        if ($entry.PSObject) {
            $props = @($entry.PSObject.Properties)
            if ($props.Count -gt 0) {
                $map = @{}
                foreach ($p in $props) { $map[$p.Name] = $p.Value }
                $items.Add($map) | Out-Null
            }
        }
    }
    return @($items)
}

function Resolve-AksKarpenterPillar {
    param ([pscustomobject]$Finding)
    $raw = if ($Finding.PSObject.Properties['Pillar']) { [string]$Finding.Pillar } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }
    if ($Finding.RuleId -eq 'karpenter.consolidation-disabled') { return 'Cost Optimization; Reliability' }
    return 'Cost Optimization'
}

function Resolve-AksKarpenterImpact {
    param ([pscustomobject]$Finding)
    $raw = if ($Finding.PSObject.Properties['Impact']) { [string]$Finding.Impact } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }

    if ($Finding.RuleId -eq 'karpenter.no-node-limit') { return 'High' }
    if ($Finding.RuleId -eq 'karpenter.consolidation-disabled') { return 'Medium' }

    if ($Finding.PSObject.Properties['NodeHours'] -and $null -ne $Finding.NodeHours) {
        $hours = [double]$Finding.NodeHours
        if ($hours -ge 500.0) { return 'High' }
        if ($hours -ge 150.0) { return 'Medium' }
        return 'Low'
    }

    if ($Finding.PSObject.Properties['ObservedPercent'] -and $null -ne $Finding.ObservedPercent) {
        $pct = [double]$Finding.ObservedPercent
        if ($pct -le 10.0) { return 'High' }
        if ($pct -le 35.0) { return 'Medium' }
        return 'Low'
    }

    return 'Low'
}

function Resolve-AksKarpenterEffort {
    param ([pscustomobject]$Finding)
    $raw = if ($Finding.PSObject.Properties['Effort']) { [string]$Finding.Effort } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }
    if ($Finding.RuleId -like 'karpenter.*') { return 'Medium' }
    return 'Low'
}

function Get-AksKarpenterBaselineTags {
    param ([pscustomobject]$Finding)
    if ($Finding.PSObject.Properties['BaselineTags'] -and $Finding.BaselineTags) {
        return @(Convert-ToStringArray $Finding.BaselineTags)
    }
    $ruleTag = switch ($Finding.RuleId) {
        'aks.idle-node' { 'Karpenter-IdleNodes' }
        'karpenter.consolidation-disabled' { 'Karpenter-Consolidation' }
        'karpenter.no-node-limit' { 'Karpenter-ProvisionerLimits' }
        'karpenter.over-provisioned' { 'Karpenter-IdleNodes' }
        default { 'Karpenter-NodeHours' }
    }
    $rbac = if ($Finding.PSObject.Properties['RbacTier']) { [string]$Finding.RbacTier } else { 'Reader' }
    $rbacTag = if ($rbac -eq 'Reader') { 'RBAC-Reader' } else { 'RBAC-ClusterAdmin' }
    return @($ruleTag, $rbacTag)
}

function Get-AksKarpenterEntityRefs {
    param ([pscustomobject]$Finding, [string]$ClusterArm)
    if ($Finding.PSObject.Properties['EntityRefs'] -and $Finding.EntityRefs) {
        return @(Convert-ToStringArray $Finding.EntityRefs)
    }
    $refs = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ClusterArm)) { $refs.Add($ClusterArm) | Out-Null }
    if ($Finding.PSObject.Properties['ProvisionerName'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.ProvisionerName)) {
        $refs.Add([string]$Finding.ProvisionerName) | Out-Null
    }
    return @($refs)
}

function Get-AksKarpenterScoreDelta {
    param ([pscustomobject]$Finding)
    if ($Finding.PSObject.Properties['ScoreDelta'] -and $null -ne $Finding.ScoreDelta) {
        return [double]$Finding.ScoreDelta
    }
    if ($Finding.PSObject.Properties['NodeHours'] -and $null -ne $Finding.NodeHours) {
        return [double]$Finding.NodeHours
    }
    if ($Finding.PSObject.Properties['ObservedPercent'] -and $null -ne $Finding.ObservedPercent) {
        return [double]$Finding.ObservedPercent
    }
    return $null
}

function Normalize-AksKarpenterCost {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -notin @('Success', 'PartialSuccess') -or -not $ToolResult.Findings) {
        return @()
    }

    $runId = [guid]::NewGuid().ToString()
    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($f in $ToolResult.Findings) {
        $entityType = if ($f.PSObject.Properties['EntityType'] -and $f.EntityType) { [string]$f.EntityType } else { 'AzureResource' }
        if ($entityType -notin @('AzureResource', 'KarpenterProvisioner')) { $entityType = 'AzureResource' }

        $rawId = if ($f.PSObject.Properties['EntityRawId'] -and $f.EntityRawId) {
            [string]$f.EntityRawId
        } elseif ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) {
            [string]$f.ResourceId
        } else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($rawId)) { continue }

        try {
            $canonical = ConvertTo-CanonicalEntityId -RawId $rawId -EntityType $entityType
            $canonicalId = $canonical.CanonicalId
            $platform    = $canonical.Platform
        } catch {
            $canonicalId = $rawId.ToLowerInvariant()
            $platform    = 'Azure'
        }

        $clusterArm = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        $subId = ''
        $rg    = ''
        if ($clusterArm -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($clusterArm -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        $severity    = ConvertTo-AksKarpenterSeverity -RawSeverity ([string]$f.Severity)
        $findingId   = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $title       = if ($f.PSObject.Properties['Title'] -and $f.Title) { [string]$f.Title } else { 'AKS Karpenter cost signal' }
        $detail      = if ($f.PSObject.Properties['Detail'] -and $f.Detail) { [string]$f.Detail } else { '' }
        $remediation = if ($f.PSObject.Properties['Remediation'] -and $f.Remediation) { [string]$f.Remediation } else { '' }
        $category    = if ($f.PSObject.Properties['Category'] -and $f.Category) { [string]$f.Category } else { 'Cost' }
        $learnMore   = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        $source      = if ($f.PSObject.Properties['Source'] -and $f.Source) { [string]$f.Source } else { 'aks-karpenter-cost' }
        $ruleId      = if ($f.PSObject.Properties['RuleId']     -and $f.RuleId)     { [string]$f.RuleId } else { '' }
        $compliant   = if ($f.PSObject.Properties['Compliant'])               { [bool]$f.Compliant } else { $false }
        $pillar      = Resolve-AksKarpenterPillar -Finding $f
        $impact      = Resolve-AksKarpenterImpact -Finding $f
        $effort      = Resolve-AksKarpenterEffort -Finding $f
        $deepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl']) { [string]$f.DeepLinkUrl } else { '' }
        $remediationSnippets = if ($f.PSObject.Properties['RemediationSnippets']) {
            @(Convert-ToHashtableArray $f.RemediationSnippets)
        } else { @() }
        $evidenceUris = if ($f.PSObject.Properties['EvidenceUris']) {
            @(Convert-ToStringArray $f.EvidenceUris)
        } else { @() }
        $baselineTags = @(Get-AksKarpenterBaselineTags -Finding $f)
        $scoreDelta = Get-AksKarpenterScoreDelta -Finding $f
        $entityRefs = @(Get-AksKarpenterEntityRefs -Finding $f -ClusterArm $clusterArm)
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and -not [string]::IsNullOrWhiteSpace([string]$f.ToolVersion)) {
            [string]$f.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion']) {
            [string]$ToolResult.ToolVersion
        } else {
            ''
        }

        $row = New-FindingRow -Id $findingId `
            -Source $source -EntityId $canonicalId -EntityType $entityType `
            -Title $title -RuleId $ruleId -Compliant $compliant -ProvenanceRunId $runId `
            -Platform $platform -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $clusterArm `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets $remediationSnippets `
            -EvidenceUris $evidenceUris -BaselineTags $baselineTags `
            -ScoreDelta $scoreDelta -EntityRefs $entityRefs `
            -ToolVersion $toolVersion

        if ($null -eq $row) { continue }

        foreach ($extra in @(
                'ClusterName', 'ClusterResourceGroup', 'ProvisionerName',
                'NodeName', 'NodeCount', 'NodeHours',
                'ObservedPercent', 'RbacTier'
            )) {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra -and [string]$f.$extra -ne '') {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
