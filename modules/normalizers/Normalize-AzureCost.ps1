#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Azure Cost (Consumption API) wrapper output.
.DESCRIPTION
    Converts v1 azure-cost wrapper output to v2 FindingRows.
    - Subscription roll-up -> EntityType=Subscription, Platform=Azure.
    - Top-N resources -> EntityType=AzureResource. MonthlyCost / Currency populated
      on the finding so EntityStore folds the cost onto the existing entity.
    All emitted findings are Severity=Info, Compliant=$true — azure-cost is an
    enrichment source, not a pass/fail tool.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Resolve-CostImpact {
    param ([double] $MonthlyCost)

    if ($MonthlyCost -gt 1000) { return 'High' }
    if ($MonthlyCost -ge 200) { return 'Medium' }
    return 'Low'
}

function Resolve-CostEffort {
    param (
        [string] $EntityType,
        [string] $CostCategory
    )

    if ($EntityType -eq 'Subscription' -or $CostCategory -eq 'SubscriptionSpend') { return 'Medium' }
    return 'Low'
}

function Resolve-CostManagementDeepLink {
    param (
        [string] $SubscriptionId,
        [string] $ResourceGroup,
        [string] $ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($SubscriptionId) -and $ResourceId -match '/subscriptions/([^/]+)') {
        $SubscriptionId = [string]$Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($ResourceGroup) -and $ResourceId -match '/resourceGroups/([^/]+)') {
        $ResourceGroup = [string]$Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { return '' }

    $base = 'https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis'
    $params = [System.Collections.Generic.List[string]]::new()
    $params.Add("subscriptionId=$([uri]::EscapeDataString($SubscriptionId))") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($ResourceGroup)) {
        $params.Add("resourceGroup=$([uri]::EscapeDataString($ResourceGroup))") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($ResourceId)) {
        $params.Add("resourceId=$([uri]::EscapeDataString($ResourceId))") | Out-Null
    }

    return "${base}?$($params -join '&')"
}

function Convert-ToRemediationSnippets {
    param ([string] $Remediation)

    if ([string]::IsNullOrWhiteSpace($Remediation)) { return @() }
    return @(@{
            language = 'text'
            code     = $Remediation.Trim()
        })
}

function Normalize-AzureCost {
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

    foreach ($f in $ToolResult.Findings) {
        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if (-not $rawId) { continue }

        $subId = ''
        $rg    = ''
        if ($rawId -match '^[0-9a-fA-F-]{36}$') { $subId = $rawId }
        elseif ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        $isSubscription = ($rawId -match '^[0-9a-fA-F-]{36}$') -or `
                          ($rawId -match '^/subscriptions/[^/]+/?$') -or `
                          ($f.PSObject.Properties['ResourceType'] -and $f.ResourceType -eq 'Microsoft.Resources/subscriptions')

        if ($isSubscription) {
            $entityType  = 'Subscription'
            $canonicalId = $subId.ToLowerInvariant()
        } else {
            $entityType = 'AzureResource'
            try   { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
            catch { $canonicalId = $rawId.ToLowerInvariant() }
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }

        $monthlyCost = 0.0
        if ($f.PSObject.Properties['MonthlyCost'] -and $null -ne $f.MonthlyCost) {
            try { $monthlyCost = [double]$f.MonthlyCost } catch { $monthlyCost = 0.0 }
        }
        $currency = if ($f.PSObject.Properties['Currency'] -and $f.Currency) { [string]$f.Currency } else { '' }
        $costCategory = if ($f.PSObject.Properties['CostCategory'] -and $f.CostCategory) { [string]$f.CostCategory } else { 'Cost' }
        $impact = Resolve-CostImpact -MonthlyCost $monthlyCost
        $effort = Resolve-CostEffort -EntityType $entityType -CostCategory $costCategory
        $deepLinkUrl = Resolve-CostManagementDeepLink -SubscriptionId $subId -ResourceGroup $rg -ResourceId $rawId
        $frameworkControl = if ($entityType -eq 'Subscription') { 'Inform' } else { 'Optimize' }
        $frameworks = @(@{ kind = 'FinOps Foundation'; controlId = $frameworkControl })
        $remediation = if ($f.PSObject.Properties['Remediation'] -and $f.Remediation) {
            [string]$f.Remediation
        } elseif ($entityType -eq 'Subscription') {
            'Review Cost Analysis for high-spend services and enforce subscription budgets with alerts.'
        } else {
            'Use Cost Analysis and Advisor to rightsize this resource or apply autoscale and schedule controls.'
        }
        $remediationSnippets = @(Convert-ToRemediationSnippets -Remediation $remediation)
        $baselineTags = @('cost', 'finops', 'azure-cost', $costCategory.ToLowerInvariant())
        if ($entityType -eq 'Subscription') {
            $baselineTags += 'subscription-spend'
        } else {
            $baselineTags += 'resource-spend'
        }
        $evidenceUris = @()
        if ($f.PSObject.Properties['LearnMoreUrl'] -and $f.LearnMoreUrl) { $evidenceUris += [string]$f.LearnMoreUrl }
        if (-not [string]::IsNullOrWhiteSpace($deepLinkUrl)) { $evidenceUris += $deepLinkUrl }
        $entityRefs = @()
        if (-not [string]::IsNullOrWhiteSpace($subId)) { $entityRefs += $subId.ToLowerInvariant() }
        if ($rawId -match '^/subscriptions/') { $entityRefs += $rawId.ToLowerInvariant() }
        [Nullable[double]]$scoreDelta = $null
        if ($monthlyCost -gt 0) { $scoreDelta = [double]$monthlyCost }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) {
            [string]$f.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) {
            [string]$ToolResult.ToolVersion
        } else {
            ''
        }
        $ruleId = if ($f.PSObject.Properties['RuleId'] -and $f.RuleId) { [string]$f.RuleId } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'azure-cost' -EntityId $canonicalId -EntityType $entityType `
            -Title ([string]$f.Title) -Compliant $true -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'Cost' -Severity 'Info' `
            -Detail ([string]$f.Detail) -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -RuleId $ruleId -Pillar 'CostOptimization' -Frameworks $frameworks `
            -Impact $impact -Effort $effort -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets $remediationSnippets -EvidenceUris $evidenceUris `
            -BaselineTags $baselineTags -ScoreDelta $scoreDelta -EntityRefs $entityRefs `
            -ToolVersion $toolVersion
        # MonthlyCost / Currency are entity-level, not part of New-FindingRow's signature.
        # Attach them to the finding so the orchestrator can fold them onto the entity.
        $row | Add-Member -NotePropertyName MonthlyCost -NotePropertyValue $monthlyCost -Force
        $row | Add-Member -NotePropertyName Currency    -NotePropertyValue $currency    -Force
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
