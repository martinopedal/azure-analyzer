#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Defender for Cloud findings.
.DESCRIPTION
    Converts Defender assessment and secure score records to schema v2 FindingRows.
    - Non-healthy assessments become AzureResource non-compliant findings.
    - Secure score becomes an informational Subscription finding.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-DefenderForCloud {
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

    foreach ($record in @($ToolResult.Findings)) {
        if (-not $record) { continue }
        $recordType = [string]($record.RecordType ?? '')

        if ($recordType -eq 'Assessment') {
            $statusCode = [string]($record.StatusCode ?? '')
            if ($statusCode.ToLowerInvariant() -in @('healthy', 'notapplicable')) { continue }

            $rawId = [string]($record.ResourceId ?? '')
            if (-not $rawId) { continue }

            $canonicalId = ''
            $subscriptionId = ''
            $resourceGroup = ''
            try {
                $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '/subscriptions/([^/]+)') { $subscriptionId = $Matches[1] }
            if ($rawId -match '/resourceGroups/([^/]+)') { $resourceGroup = $Matches[1] }

            $assessmentId = [string]($record.AssessmentId ?? [guid]::NewGuid().ToString())
            $title = [string]($record.Title ?? 'Defender recommendation')
            $severity = switch -Regex ([string]($record.Severity ?? 'Medium').ToLowerInvariant()) {
                'critical'         { 'Critical' }
                'high'             { 'High' }
                'medium|moderate'  { 'Medium' }
                'low'              { 'Low' }
                'info'             { 'Info' }
                default            { 'Medium' }
            }
            $detail = [string]($record.Description ?? '')
            $remediation = [string]($record.Remediation ?? '')
            $learnMore = [string]($record.LearnMoreUrl ?? '')

            $row = New-FindingRow -Id ("defender-assessment-$assessmentId") `
                -Source 'defender-for-cloud' -EntityId $canonicalId -EntityType 'AzureResource' `
                -Title $title -Compliant $false -ProvenanceRunId $runId `
                -Platform 'Azure' -Category 'Defender for Cloud' -Severity $severity `
                -Detail $detail -Remediation $remediation `
                -LearnMoreUrl $learnMore -ResourceId $rawId `
                -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
            $normalized.Add($row)
            continue
        }

        if ($recordType -eq 'SecureScore') {
            $subscriptionId = [string]($record.SubscriptionId ?? $ToolResult.SubscriptionId ?? '')
            if (-not $subscriptionId) { continue }

            try {
                $canonical = ConvertTo-CanonicalEntityId -RawId $subscriptionId -EntityType 'Subscription'
                $entityId = $canonical.CanonicalId
            } catch {
                $entityId = $subscriptionId.ToLowerInvariant()
            }

            $current = [double]($record.Current ?? 0)
            $max = [double]($record.Max ?? 0)
            $percentage = [double]($record.Percentage ?? $(if ($max -gt 0) { [Math]::Round(($current / $max) * 100, 2) } else { 0 }))
            $detail = "Current secure score: $current of $max ($percentage%)."

            $row = New-FindingRow -Id ("defender-securescore-$subscriptionId") `
                -Source 'defender-for-cloud' -EntityId $entityId -EntityType 'Subscription' `
                -Title 'Defender for Cloud Secure Score' -Compliant $true -ProvenanceRunId $runId `
                -Platform 'Azure' -Category 'Defender for Cloud' -Severity 'Info' `
                -Detail $detail -ResourceId "/subscriptions/$subscriptionId" `
                -SubscriptionId $subscriptionId
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
