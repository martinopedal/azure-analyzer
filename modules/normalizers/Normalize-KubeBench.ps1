#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for kube-bench wrapper output.
.DESCRIPTION
    Converts v1 kube-bench wrapper output to v2 FindingRows.
    Maps kube-bench FAIL/WARN checks onto the AKS cluster AzureResource entity.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-KubeBench {
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
        $statusRaw = if ($f.PSObject.Properties['Status'] -and $f.Status) { [string]$f.Status } else { '' }
        if ($statusRaw -and $statusRaw -notmatch '^(?i)(FAIL|WARN)$') { continue }

        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if (-not $rawId) { continue }

        $subId = ''
        $rg = ''
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        try { $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        $severity = if ($f.PSObject.Properties['Severity'] -and $f.Severity) {
            switch -Regex ([string]$f.Severity) {
                '^(?i)critical$' { 'Critical' }
                '^(?i)high$'     { 'High' }
                '^(?i)medium$'   { 'Medium' }
                '^(?i)low$'      { 'Low' }
                '^(?i)info$'     { 'Info' }
                default          { 'Medium' }
            }
        } else {
            if ($statusRaw -match '^(?i)FAIL$') { 'High' } else { 'Medium' }
        }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        $title = if ($f.PSObject.Properties['Title'] -and $f.Title) { [string]$f.Title } else { 'kube-bench finding' }
        $detail = if ($f.PSObject.Properties['Detail']) { [string]$f.Detail } else { '' }
        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $learnMore = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }

        $row = New-FindingRow -Id $findingId `
            -Source 'kube-bench' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant $false -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'KubernetesNodeSecurity' -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg

        if ($f.PSObject.Properties['ControlId'] -and $f.ControlId) {
            $row | Add-Member -NotePropertyName ControlId -NotePropertyValue ([string]$f.ControlId) -Force
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
