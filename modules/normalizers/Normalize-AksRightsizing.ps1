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

        $canonicalId = $rawId.ToLowerInvariant()
        try {
            $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId
        } catch {
            $canonicalId = $rawId.ToLowerInvariant()
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

        $row = New-FindingRow -Id $findingId `
            -Source $source -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMoreUrl -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg

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
