#Requires -Version 7.4
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function ConvertTo-AksRightsizingSeverity {
    param([string]$RawSeverity)
    switch -Regex (($RawSeverity ?? '').ToLowerInvariant()) {
        '^critical$' { 'Critical' }
        '^high$' { 'High' }
        '^medium$' { 'Medium' }
        '^low$' { 'Low' }
        '^info' { 'Info' }
        default { 'Info' }
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
            foreach ($key in $entry.Keys) { $map[[string]$key] = $entry[$key] }
            $items.Add($map) | Out-Null
            continue
        }
        if ($entry.PSObject -and $entry.PSObject.Properties.Count -gt 0) {
            $map = @{}
            foreach ($prop in @($entry.PSObject.Properties)) { $map[$prop.Name] = $prop.Value }
            $items.Add($map) | Out-Null
        }
    }
    return @($items)
}

function Resolve-AksRightsizingPillar {
    param([string]$FindingCategory)
    switch -Regex (($FindingCategory ?? '').ToLowerInvariant()) {
        'overprovisioned|idle' { return 'Cost Optimization' }
        'underprovisioned|oomkilled|missinghpa' { return 'Performance Efficiency' }
        default { return 'Performance Efficiency' }
    }
}

function Get-AksSignalPercent {
    param(
        [string]$FindingCategory,
        [double]$ObservedPercent
    )

    if (($FindingCategory ?? '') -match '(?i)overprovisioned|idle') {
        return [math]::Round([math]::Max(0, (100.0 - $ObservedPercent)), 2)
    }
    return [math]::Round([math]::Max(0, $ObservedPercent), 2)
}

function Resolve-AksRightsizingImpact {
    param(
        [string]$FindingCategory,
        [double]$ObservedPercent
    )

    $category = ($FindingCategory ?? '').ToLowerInvariant()
    $signal = Get-AksSignalPercent -FindingCategory $FindingCategory -ObservedPercent $ObservedPercent
    if ($category -match 'overprovisioned|idle') {
        if ($signal -ge 80) { return 'High' }
        if ($signal -ge 50) { return 'Medium' }
        return 'Low'
    }

    if ($signal -ge 90) { return 'High' }
    if ($signal -ge 50) { return 'Medium' }
    return 'Low'
}

function Resolve-AksRightsizingEffort {
    param([string]$FindingCategory)
    switch -Regex (($FindingCategory ?? '').ToLowerInvariant()) {
        'missinghpa' { return 'Medium' }
        'oomkilled' { return 'High' }
        default { return 'Low' }
    }
}

function Resolve-AksBaselineTags {
    param(
        [string]$FindingCategory,
        [string]$MetricType
    )

    $tags = [System.Collections.Generic.List[string]]::new()
    $category = ($FindingCategory ?? '').Trim()
    $metric = ($MetricType ?? '').Trim()
    switch -Regex ($category.ToLowerInvariant()) {
        'overprovisionedcpu|underprovisionedcpu' { $tags.Add('AKS-RightSizing-CPU') | Out-Null }
        'overprovisionedmemory|underprovisionedmemory' { $tags.Add('AKS-RightSizing-Memory') | Out-Null }
        'missinghpa' { $tags.Add('AKS-MissingHPA') | Out-Null }
        'oomkilled' { $tags.Add('AKS-OOMKilled') | Out-Null }
    }
    if (-not [string]::IsNullOrWhiteSpace($category)) { $tags.Add("AKS-$category") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($metric)) { $tags.Add("AKS-RightSizing-$($metric.ToUpperInvariant())") | Out-Null }
    return @($tags | Select-Object -Unique)
}

function New-AksWorkloadEntityId {
    param(
        [string]$ClusterResourceId,
        [string]$Namespace,
        [string]$WorkloadName
    )
    $clusterId = ($ClusterResourceId ?? '').Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($clusterId)) { return '' }
    $ns = if ([string]::IsNullOrWhiteSpace($Namespace)) { '_cluster' } else { $Namespace.Trim().ToLowerInvariant() }
    $workload = if ([string]::IsNullOrWhiteSpace($WorkloadName)) { '_cluster' } else { $WorkloadName.Trim().ToLowerInvariant() }
    return "$clusterId/namespaces/$ns/workloads/$workload"
}

function Normalize-AksRightsizing {
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
        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if ([string]::IsNullOrWhiteSpace($rawId)) { continue }

        $namespace = if ($f.PSObject.Properties['Namespace']) { [string]$f.Namespace } else { '' }
        $workloadName = if ($f.PSObject.Properties['WorkloadName']) { [string]$f.WorkloadName } else { '' }
        $findingCategory = if ($f.PSObject.Properties['FindingCategory']) { [string]$f.FindingCategory } else { '' }
        $metricType = if ($f.PSObject.Properties['MetricType']) { [string]$f.MetricType } else { '' }
        $observedPercent = if ($f.PSObject.Properties['ObservedPercent']) { [double]$f.ObservedPercent } else { 0.0 }
        $entityRawId = New-AksWorkloadEntityId -ClusterResourceId $rawId -Namespace $namespace -WorkloadName $workloadName
        if ([string]::IsNullOrWhiteSpace($entityRawId)) { $entityRawId = $rawId }

        $canonicalId = $entityRawId.ToLowerInvariant()
        try {
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $entityRawId -EntityType 'AzureResource').CanonicalId
        } catch {
            $canonicalId = $entityRawId.ToLowerInvariant()
        }

        $subId = ''
        $rg = ''
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        $severity = ConvertTo-AksRightsizingSeverity -RawSeverity ([string]$f.Severity)
        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $title = if ($f.PSObject.Properties['Title'] -and $f.Title) { [string]$f.Title } else { 'AKS rightsizing signal' }
        $detail = if ($f.PSObject.Properties['Detail'] -and $f.Detail) { [string]$f.Detail } else { '' }
        $remediation = if ($f.PSObject.Properties['Remediation'] -and $f.Remediation) { [string]$f.Remediation } else { '' }
        $category = if ($f.PSObject.Properties['Category'] -and $f.Category) { [string]$f.Category } else { 'Performance' }
        $learnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        $source = if ($f.PSObject.Properties['Source'] -and $f.Source) { [string]$f.Source } else { 'aks-rightsizing' }
        $compliant = $false
        if ($f.PSObject.Properties['Compliant']) { $compliant = [bool]$f.Compliant }
        $pillar = if ($f.PSObject.Properties['Pillar'] -and $f.Pillar) { [string]$f.Pillar } else { Resolve-AksRightsizingPillar -FindingCategory $findingCategory }
        $impact = if ($f.PSObject.Properties['Impact'] -and $f.Impact) { [string]$f.Impact } else { Resolve-AksRightsizingImpact -FindingCategory $findingCategory -ObservedPercent $observedPercent }
        $effort = if ($f.PSObject.Properties['Effort'] -and $f.Effort) { [string]$f.Effort } else { Resolve-AksRightsizingEffort -FindingCategory $findingCategory }
        $deepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl'] -and $f.DeepLinkUrl) { [string]$f.DeepLinkUrl } else { $learnMoreUrl }
        $remediationSnippets = if ($f.PSObject.Properties['RemediationSnippets']) { @(Convert-ToHashtableArray $f.RemediationSnippets) } else { @() }
        $evidenceUris = if ($f.PSObject.Properties['EvidenceUris']) { @(Convert-ToStringArray $f.EvidenceUris) } else { @() }
        $baselineTags = if ($f.PSObject.Properties['BaselineTags']) { @(Convert-ToStringArray $f.BaselineTags) } else { @(Resolve-AksBaselineTags -FindingCategory $findingCategory -MetricType $metricType) }
        $scoreDelta = if ($f.PSObject.Properties['ScoreDelta'] -and $null -ne $f.ScoreDelta) { [double]$f.ScoreDelta } else { [double](Get-AksSignalPercent -FindingCategory $findingCategory -ObservedPercent $observedPercent) }
        $entityRefs = if ($f.PSObject.Properties['EntityRefs']) { @(Convert-ToStringArray $f.EntityRefs) } else { @($rawId, "namespace:$namespace", "workload:$workloadName") }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) { [string]$f.ToolVersion } elseif ($ToolResult.PSObject.Properties['ToolVersion']) { [string]$ToolResult.ToolVersion } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source $source -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMoreUrl -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets $remediationSnippets `
            -EvidenceUris $evidenceUris -BaselineTags $baselineTags `
            -ScoreDelta $scoreDelta -EntityRefs $entityRefs -ToolVersion $toolVersion

        if ($null -eq $row) { continue }

        foreach ($extra in @(
                'FindingCategory',
                'ClusterName',
                'ClusterResourceGroup',
                'Namespace',
                'WorkloadName',
                'ContainerName',
                'MetricType',
                'ObservedPercent',
                'RecommendedMillicores',
                'RecommendedMemoryMiB'
            )) {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra -and [string]$f.$extra -ne '') {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
