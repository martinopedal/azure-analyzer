#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for kubescape findings.
.DESCRIPTION
    Converts kubescape wrapper output to schema v2 FindingRow objects.
    Platform=Azure, EntityType=AzureResource.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-ValueOrDefault {
    param ([object]$Obj, [string]$Name, [object]$Default = '')
    if ($null -eq $Obj) { return $Default }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Normalize-Kubescape {
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

    foreach ($finding in $ToolResult.Findings) {
        $rawId = [string](Get-ValueOrDefault -Obj $finding -Name 'ResourceId' -Default '')
        $subId = ''
        $rg = ''
        $canonicalId = ''

        if ($rawId -and $rawId -match '^/subscriptions/') {
            try {
                $canonicalId = ConvertTo-CanonicalArmId -ArmId $rawId
            } catch {
                $canonicalId = $rawId.ToLowerInvariant()
            }
            if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
            if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }
        }

        $findingId = [string](Get-ValueOrDefault -Obj $finding -Name 'Id' -Default ([guid]::NewGuid().ToString()))
        if (-not $canonicalId) {
            $canonicalId = "kubescape/$findingId"
        }

        $title = [string](Get-ValueOrDefault -Obj $finding -Name 'Title' -Default 'Kubescape finding')
        $category = [string](Get-ValueOrDefault -Obj $finding -Name 'Category' -Default 'Kubernetes Runtime')

        $rawSeverity = [string](Get-ValueOrDefault -Obj $finding -Name 'Severity' -Default 'Medium')
        $severity = switch -Regex ($rawSeverity.ToLowerInvariant()) {
            'critical'         { 'Critical' }
            'high'             { 'High' }
            'medium|moderate'  { 'Medium' }
            'low'              { 'Low' }
            default            { 'Info' }
        }

        $compliant = [bool](Get-ValueOrDefault -Obj $finding -Name 'Compliant' -Default $false)
        $detail = [string](Get-ValueOrDefault -Obj $finding -Name 'Detail' -Default '')
        $remediation = [string](Get-ValueOrDefault -Obj $finding -Name 'Remediation' -Default '')
        $learnMore = [string](Get-ValueOrDefault -Obj $finding -Name 'LearnMoreUrl' -Default '')

        $controls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $cisIds = Get-ValueOrDefault -Obj $finding -Name 'CisIds' -Default @()
        foreach ($cisId in @($cisIds)) {
            $normalizedControl = [string]$cisId
            if (-not [string]::IsNullOrWhiteSpace($normalizedControl) -and $normalizedControl -match '^CIS-\d+(\.\d+)+$') {
                $null = $controls.Add($normalizedControl.ToUpperInvariant())
            }
        }

        if ($controls.Count -eq 0) {
            $controlId = [string](Get-ValueOrDefault -Obj $finding -Name 'ControlId' -Default '')
            if ($controlId -match '([0-9]+(?:\.[0-9]+)+)') {
                $null = $controls.Add("CIS-$($Matches[1])".ToUpperInvariant())
            }
        }

        if ($controls.Count -eq 0 -and $detail) {
            foreach ($m in [regex]::Matches($detail, '([0-9]+(?:\.[0-9]+)+)')) {
                $null = $controls.Add("CIS-$($m.Groups[1].Value)".ToUpperInvariant())
            }
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'kubescape' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title $title -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId ($rawId ?? '') `
            -SubscriptionId $subId -ResourceGroup $rg -Controls @($controls | Sort-Object)
        $normalized.Add($row)
    }

    return @($normalized)
}
