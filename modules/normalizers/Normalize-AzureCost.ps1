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

        $row = New-FindingRow -Id $findingId `
            -Source 'azure-cost' -EntityId $canonicalId -EntityType $entityType `
            -Title ([string]$f.Title) -Compliant $true -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'Cost' -Severity 'Info' `
            -Detail ([string]$f.Detail) -Remediation '' `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg
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
