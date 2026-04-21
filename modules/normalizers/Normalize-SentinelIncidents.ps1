#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Microsoft Sentinel incidents wrapper output.
.DESCRIPTION
    Converts v1 sentinel-incidents wrapper output to v2 FindingRows.
    - Each active incident maps to EntityType=AzureResource (workspace ARM resource),
      keyed to the Log Analytics workspace hosting Sentinel.
    - Severity is mapped from Sentinel's native values (High/Medium/Low/Informational).
    - All incidents are Compliant=false (active, unresolved incidents).
    - Extra fields (IncidentNumber, IncidentStatus, AlertCount, Classification,
      IncidentUrl, ProviderName) are attached via Add-Member.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Normalize-SentinelIncidents {
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

    function ConvertTo-StringArray {
        param ([object] $Value)

        if ($null -eq $Value) { return @() }

        $items = if ($Value -is [string]) {
            $trimmed = $Value.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                @()
            } elseif ($trimmed.StartsWith('[') -or $trimmed.StartsWith('{')) {
                try { @($trimmed | ConvertFrom-Json -Depth 30) } catch { @($trimmed) }
            } else {
                @($trimmed)
            }
        } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            @($Value)
        } else {
            @($Value)
        }

        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $result = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $text = $text.Trim()
            if ($seen.Add($text)) { $result.Add($text) }
        }
        return $result.ToArray()
    }

    function ConvertTo-Frameworks {
        param (
            [object] $FrameworksRaw,
            [string[]] $MitreTechniques
        )

        $frameworks = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($raw in @($FrameworksRaw)) {
            if ($null -eq $raw) { continue }
            if ($raw -is [System.Collections.IDictionary]) {
                $frameworks.Add(@{
                    Name      = [string]$raw['Name']
                    Controls  = @($raw['Controls'])
                    ControlId = [string]($raw['ControlId'] ?? $raw['controlId'])
                    kind      = [string]($raw['kind'] ?? $raw['Name'])
                }) | Out-Null
                continue
            }
            if ($raw.PSObject) {
                $frameworks.Add(@{
                    Name      = [string]$raw.Name
                    Controls  = @($raw.Controls)
                    ControlId = [string]($raw.ControlId ?? $raw.controlId)
                    kind      = [string]($raw.kind ?? $raw.Name)
                }) | Out-Null
            }
        }

        if ($frameworks.Count -eq 0) {
            foreach ($techniqueId in @($MitreTechniques)) {
                if ([string]::IsNullOrWhiteSpace([string]$techniqueId)) { continue }
                $frameworks.Add(@{
                    Name      = 'MITRE ATT&CK'
                    Controls  = @($techniqueId)
                    ControlId = [string]$techniqueId
                    kind      = 'MITRE ATT&CK'
                }) | Out-Null
            }
        }

        return $frameworks.ToArray()
    }

    foreach ($f in $ToolResult.Findings) {
        $rawId = if ($f.PSObject.Properties['ResourceId'] -and $f.ResourceId) { [string]$f.ResourceId } else { '' }
        if (-not $rawId) { continue }

        $subId = ''
        $rg    = ''
        if ($rawId -match '/subscriptions/([^/]+)') { $subId = $Matches[1] }
        if ($rawId -match '/resourceGroups/([^/]+)') { $rg = $Matches[1] }

        # Sentinel incidents are workspace-scoped; entity is the workspace ARM resource
        $entityType = 'AzureResource'
        try   { $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawId -EntityType 'AzureResource').CanonicalId }
        catch { $canonicalId = $rawId.ToLowerInvariant() }

        # Map Sentinel severity to schema casing (Critical/High/Medium/Low/Info)
        $sevRaw = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { [string]$f.Severity } else { 'Medium' }
        $sev = switch -Regex ($sevRaw) {
            '^(?i)critical$'      { 'Critical' }
            '^(?i)high$'          { 'High' }
            '^(?i)medium$'        { 'Medium' }
            '^(?i)low$'           { 'Low' }
            '^(?i)info.*'         { 'Info' }
            default               { 'Medium' }
        }

        $compliant = $false
        if ($f.PSObject.Properties['Compliant']) { $compliant = [bool]$f.Compliant }

        $findingId = if ($f.PSObject.Properties['Id'] -and $f.Id) { [string]$f.Id } else { [guid]::NewGuid().ToString() }

        $remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        $mitreTactics = ConvertTo-StringArray -Value $(if ($f.PSObject.Properties['MitreTactics']) { $f.MitreTactics } else { @() })
        $mitreTechniques = ConvertTo-StringArray -Value $(if ($f.PSObject.Properties['MitreTechniques']) { $f.MitreTechniques } else { @() })
        $entityRefs = ConvertTo-StringArray -Value $(if ($f.PSObject.Properties['EntityRefs']) { $f.EntityRefs } else { @() })
        $evidenceUris = ConvertTo-StringArray -Value $(if ($f.PSObject.Properties['EvidenceUris']) { $f.EvidenceUris } else { @() })
        $frameworks = ConvertTo-Frameworks -FrameworksRaw $(if ($f.PSObject.Properties['Frameworks']) { $f.Frameworks } else { @() }) -MitreTechniques $mitreTechniques
        $deepLink = if ($f.PSObject.Properties['DeepLinkUrl'] -and $f.DeepLinkUrl) { [string]$f.DeepLinkUrl } elseif ($f.PSObject.Properties['IncidentUrl'] -and $f.IncidentUrl) { [string]$f.IncidentUrl } else { '' }
        $toolVersion = if ($f.PSObject.Properties['ToolVersion'] -and $f.ToolVersion) { [string]$f.ToolVersion } else { '2022-10-01' }
        $pillar = if ($f.PSObject.Properties['Pillar'] -and $f.Pillar) { [string]$f.Pillar } else { 'Security' }

        $row = New-FindingRow -Id $findingId `
            -Source 'sentinel-incidents' -EntityId $canonicalId -EntityType $entityType `
            -Title ([string]$f.Title) -Compliant $compliant -ProvenanceRunId $runId `
            -Platform 'Azure' -Category 'ThreatDetection' -Severity $sev `
            -Detail ([string]$f.Detail) `
            -Remediation $remediation `
            -LearnMoreUrl ([string]$f.LearnMoreUrl) -ResourceId $rawId `
            -SubscriptionId $subId -ResourceGroup $rg `
            -Pillar $pillar `
            -Frameworks $frameworks `
            -DeepLinkUrl $deepLink `
            -EvidenceUris $evidenceUris `
            -MitreTactics $mitreTactics `
            -MitreTechniques $mitreTechniques `
            -EntityRefs $entityRefs `
            -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
