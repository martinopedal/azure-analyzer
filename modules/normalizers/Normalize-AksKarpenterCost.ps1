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

        $row = New-FindingRow -Id $findingId `
            -Source $source -EntityId $canonicalId -EntityType $entityType `
            -Title $title -RuleId $ruleId -Compliant $compliant -ProvenanceRunId $runId `
            -Platform $platform -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $clusterArm `
            -SubscriptionId $subId -ResourceGroup $rg

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
