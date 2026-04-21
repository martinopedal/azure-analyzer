#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Microsoft Sentinel coverage / posture wrapper output.
.DESCRIPTION
    Converts v1 sentinel-coverage wrapper output to v2 FindingRows.
    All findings target the workspace ARM resource (EntityType=AzureResource,
    Platform=Azure). Severity is mapped case-insensitively to the schema's
    five-level enum (Critical/High/Medium/Low/Info). Tool-specific metadata
    (RuleId, WatchlistAlias, ConnectorCount, HuntingQueryCount, etc.) is
    attached via Add-Member as out-of-schema extras.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-SentinelCoverage {
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
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        try   { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        $sevRaw = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Medium' }
        $sev = switch -Regex ($sevRaw) {
            '^(?i)critical$'  { 'Critical' }
            '^(?i)high$'      { 'High' }
            '^(?i)medium$'    { 'Medium' }
            '^(?i)low$'       { 'Low' }
            '^(?i)info.*'     { 'Info' }
            default           { 'Medium' }
        }

        $compliant = $false
        if ($f.PSObject.Properties['Compliant']) { $compliant = [bool]$f.Compliant }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }

        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $learnMore   = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        $category    = if ($f.PSObject.Properties['Category'] -and $f.Category) { [string]$f.Category } else { 'ThreatDetection' }
        $ruleId      = if ($f.PSObject.Properties['RuleId'] -and $f.RuleId) { [string]$f.RuleId } else { '' }
        $pillar      = if ($f.PSObject.Properties['Pillar'] -and $f.Pillar) { [string]$f.Pillar } else { 'Security' }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) { [string]$f.ToolVersion } else { '' }
        $deepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl'] -and $f.DeepLinkUrl) { [string]$f.DeepLinkUrl } else { '' }
        $frameworks  = if ($f.PSObject.Properties['Frameworks'] -and $f.Frameworks) { @($f.Frameworks) } else { @() }
        $mitreTactics = if ($f.PSObject.Properties['MitreTactics'] -and $f.MitreTactics) { @($f.MitreTactics | ForEach-Object { [string]$_ }) } else { @() }
        $mitreTechniques = if ($f.PSObject.Properties['MitreTechniques'] -and $f.MitreTechniques) { @($f.MitreTechniques | ForEach-Object { [string]$_ }) } else { @() }
        $entityRefs = if ($f.PSObject.Properties['EntityRefs'] -and $f.EntityRefs) {
            @($f.EntityRefs | ForEach-Object { [string]$_ })
        } else {
            @([string]$canonicalId)
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'sentinel-coverage' -EntityId $canonicalId -EntityType 'AzureResource' `
            -Title ([string]$f.Title) -RuleId $ruleId -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category $category -Severity $sev `
            -Detail ([string]$f.Detail) `
            -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Frameworks $frameworks `
            -Pillar $pillar `
            -DeepLinkUrl $deepLinkUrl `
            -MitreTactics $mitreTactics `
            -MitreTechniques $mitreTechniques `
            -EntityRefs $entityRefs `
            -ToolVersion $toolVersion

        if ($null -eq $row) { continue }

        # Attach Sentinel coverage extras (out-of-schema).
        foreach ($extra in 'RuleDisplayName', 'LastModifiedUtc', 'AgeDays',
                            'WatchlistAlias', 'WatchlistName', 'DefaultDuration', 'TtlDays', 'ItemCount',
                            'ConnectorCount', 'MinExpected',
                            'AnalyticRuleCount', 'HuntingQueryCount') {
            if ($f.PSObject.Properties[$extra] -and $null -ne $f.$extra) {
                $row | Add-Member -NotePropertyName $extra -NotePropertyValue $f.$extra -Force
            }
        }

        $normalized.Add($row)
    }

    return @($normalized)
}
