#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for FinOps idle/unused resource signals.
.DESCRIPTION
    Converts v1 finops wrapper output to schema v2 FindingRows.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function ConvertTo-FinOpsSeverity {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string] $RawSeverity,
        [AllowNull()]
        [double] $EstimatedMonthlyCost
    )

    if (-not [string]::IsNullOrWhiteSpace($RawSeverity)) {
        switch -Regex ($RawSeverity.ToLowerInvariant()) {
            '^critical$'        { return 'Critical' }
            '^high$'            { return 'High' }
            '^(medium|moderate)$' { return 'Medium' }
            '^low$'             { return 'Low' }
            '^info(nformational)?$' { }
            default             { }
        }
    }

    if ($EstimatedMonthlyCost -gt 500) { return 'Medium' }
    if ($EstimatedMonthlyCost -ge 50) { return 'Low' }
    return 'Info'
}

function Resolve-FinOpsImpact {
    param ([double] $EstimatedMonthlyCost)
    if ($EstimatedMonthlyCost -gt 500) { return 'High' }
    if ($EstimatedMonthlyCost -ge 100) { return 'Medium' }
    return 'Low'
}

function Resolve-FinOpsEffort {
    param (
        [string] $DetectionCategory,
        [string] $RuleId,
        [string] $Title,
        [string] $ResourceType
    )

    $text = ("$DetectionCategory $RuleId $Title $ResourceType").ToLowerInvariant()

    if ($text -match 'stopped virtual machines|stopped vm|deallocated|idlevm|virtualmachines') { return 'Low' }
    if ($text -match 'unattached|orphaned|orphaneddisk|managed disk|snapshot') { return 'Low' }
    if ($text -match 'public ip|empty resource groups') { return 'Low' }
    if ($text -match 'oversizedsku|appserviceplanidlecpu|app service plan|serverfarms|rightsize|sku') { return 'Medium' }
    if ($text -match 'architecturalredesign|network controls|load balancer|networksecuritygroups|nsg') { return 'High' }
    return 'Medium'
}

function Resolve-CostManagementDeepLink {
    param (
        [string] $SubscriptionId,
        [string] $ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        if ($ResourceId -match '/subscriptions/([^/]+)') { $SubscriptionId = [string]$Matches[1] }
    }
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { return '' }

    $scope = "/subscriptions/$SubscriptionId"
    $scopeEncoded = [uri]::EscapeDataString($scope)
    $base = "https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis/openingScope/$scopeEncoded"
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $base }
    return "${base}?resourceId=$([uri]::EscapeDataString($ResourceId))"
}

function Convert-ToRemediationSnippets {
    param ([string] $Recommendation)

    if ([string]::IsNullOrWhiteSpace($Recommendation)) { return @() }
    return @(
        @{ language = 'bash'; content = "# $Recommendation" },
        @{ language = 'powershell'; content = "# $Recommendation" }
    )
}

function Normalize-FinOpsSignals {
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

        $monthlyCost = 0.0
        if ($f.PSObject.Properties['EstimatedMonthlyCost'] -and $null -ne $f.EstimatedMonthlyCost) {
            try { $monthlyCost = [double]$f.EstimatedMonthlyCost } catch { $monthlyCost = 0.0 }
        }
        $currency = if ($f.PSObject.Properties['Currency'] -and $f.Currency) { [string]$f.Currency } else { '' }

        $severity = ConvertTo-FinOpsSeverity -RawSeverity ([string]$f.Severity) -EstimatedMonthlyCost $monthlyCost
        $detail = if ($f.PSObject.Properties['Detail'] -and $f.Detail) { [string]$f.Detail } else { '' }
        if ($monthlyCost -gt 0) {
            $detail = "$detail Estimated monthly waste: $monthlyCost $currency."
        }
        $detectionCategory = if ($f.PSObject.Properties['DetectionCategory'] -and $f.DetectionCategory) { [string]$f.DetectionCategory } else { '' }
        $ruleId = if ($f.PSObject.Properties['RuleId'] -and $f.RuleId) { [string]$f.RuleId } else { '' }
        $remediation = 'Review whether this resource can be deleted, downscaled, or rightsized.'
        if ($detectionCategory -eq 'AppServicePlanIdleCpu') {
            $remediation = 'Review App Service Plan utilization and rightsize SKU/instance count or consolidate workloads when average CPU stays below 5% for 30 days.'
        } elseif ($detectionCategory -eq 'AppServicePlanIdleCpuMetricsDegraded') {
            $remediation = 'Grant Azure Monitor metrics read access (for example Monitoring Reader) and re-run finops so App Service Plan CPU idle signals can be evaluated.'
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $title = if ($f.PSObject.Properties['Title'] -and $f.Title) { [string]$f.Title } else { 'FinOps idle resource signal' }
        $category = if ($f.PSObject.Properties['Category'] -and $f.Category) { [string]$f.Category } else { 'Cost' }
        $resourceType = if ($f.PSObject.Properties['ResourceType'] -and $f.ResourceType) { [string]$f.ResourceType } else { '' }
        $impact = Resolve-FinOpsImpact -EstimatedMonthlyCost $monthlyCost
        $effort = Resolve-FinOpsEffort -DetectionCategory $detectionCategory -RuleId $ruleId -Title $title -ResourceType $resourceType
        $deepLinkUrl = Resolve-CostManagementDeepLink -SubscriptionId $subId -ResourceId $rawId
        $queryId = if ($f.PSObject.Properties['QueryId'] -and $f.QueryId) { [string]$f.QueryId } else { '' }
        $queryEvidenceUrl = if ([string]::IsNullOrWhiteSpace($queryId)) {
            'https://github.com/martinopedal/alz-graph-queries'
        } else {
            "https://github.com/martinopedal/alz-graph-queries/search?q=$([uri]::EscapeDataString($queryId))"
        }
        $evidenceUris = @($queryEvidenceUrl)
        if (-not [string]::IsNullOrWhiteSpace($deepLinkUrl)) { $evidenceUris += $deepLinkUrl }
        $recommendation = if ($f.PSObject.Properties['Recommendation'] -and $f.Recommendation) { [string]$f.Recommendation } else { $remediation }
        $remediationSnippets = @(Convert-ToRemediationSnippets -Recommendation $recommendation)
        [Nullable[double]]$scoreDelta = $null
        if ($monthlyCost -gt 0) { $scoreDelta = [double]$monthlyCost }
        $entityRefs = @()
        if (-not [string]::IsNullOrWhiteSpace($subId)) { $entityRefs += $subId }
        if (-not [string]::IsNullOrWhiteSpace($rawId)) { $entityRefs += $rawId }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) {
            [string]$f.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) {
            [string]$ToolResult.ToolVersion
        } else {
            ''
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'finops' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -RuleId $ruleId -Pillar 'Cost Optimization' -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets $remediationSnippets `
            -EvidenceUris $evidenceUris -ScoreDelta $scoreDelta -EntityRefs $entityRefs `
            -ToolVersion $toolVersion
        if ($null -eq $row) { continue }

        $row | Add-Member -NotePropertyName MonthlyCost -NotePropertyValue $monthlyCost -Force
        $row | Add-Member -NotePropertyName Currency -NotePropertyValue $currency -Force
        if (-not [string]::IsNullOrWhiteSpace($detectionCategory)) {
            $row | Add-Member -NotePropertyName DetectionCategory -NotePropertyValue $detectionCategory -Force
        }
        $normalized.Add($row)
    }

    return @($normalized)
}
