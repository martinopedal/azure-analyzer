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

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $title = if ($f.PSObject.Properties['Title'] -and $f.Title) { [string]$f.Title } else { 'FinOps idle resource signal' }
        $category = if ($f.PSObject.Properties['Category'] -and $f.Category) { [string]$f.Category } else { 'Cost' }

        $row = New-FindingRow -Id $findingId `
            -Source 'finops' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation 'Review whether this resource can be deleted, downscaled, or rightsized.' `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg
        if ($null -eq $row) { continue }

        $row | Add-Member -NotePropertyName MonthlyCost -NotePropertyValue $monthlyCost -Force
        $row | Add-Member -NotePropertyName Currency -NotePropertyValue $currency -Force
        if ($f.PSObject.Properties['RuleId'] -and $f.RuleId) {
            $row | Add-Member -NotePropertyName RuleId -NotePropertyValue ([string]$f.RuleId) -Force
        }
        if ($f.PSObject.Properties['DetectionCategory']) {
            $row | Add-Member -NotePropertyName DetectionCategory -NotePropertyValue ([string]$f.DetectionCategory) -Force
        }
        $normalized.Add($row)
    }

    return @($normalized)
}
