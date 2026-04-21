#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for Maester (Entra ID security) findings.
.DESCRIPTION
    Converts raw Maester wrapper output to v3 FindingRow objects.
    Platform=Entra, EntityType=Tenant. All Maester findings map to a single
    synthetic tenant entity.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function ConvertTo-MaesterStringArray {
    param([object] $Value)
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) { $values.Add($item.Trim()) | Out-Null }
            continue
        }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($nested in @(ConvertTo-MaesterStringArray -Value $item)) {
                if (-not [string]::IsNullOrWhiteSpace($nested)) { $values.Add($nested) | Out-Null }
            }
            continue
        }
        $candidate = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $values.Add($candidate.Trim()) | Out-Null }
    }
    return @($values | Select-Object -Unique)
}

function ConvertTo-MaesterEntityRefs {
    param(
        [string] $TenantId,
        [string[]] $RawRefs
    )
    $refs = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        try {
            $refs.Add((ConvertTo-CanonicalEntityId -RawId $TenantId -EntityType 'Tenant').CanonicalId) | Out-Null
        } catch {
            $refs.Add($TenantId.ToLowerInvariant()) | Out-Null
        }
    }

    foreach ($raw in ConvertTo-MaesterStringArray -Value $RawRefs) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if ($raw -match '^(?i)tenant:') {
            $refs.Add($raw.ToLowerInvariant()) | Out-Null
            continue
        }
        if ($raw -match '^[0-9a-fA-F-]{36}$' -or $raw -match '^(?i)(appid|objectid):[0-9a-fA-F-]{36}$') {
            try {
                $refs.Add((ConvertTo-CanonicalEntityId -RawId $raw -EntityType 'ServicePrincipal').CanonicalId) | Out-Null
            } catch {
                $refs.Add($raw.ToLowerInvariant()) | Out-Null
            }
            continue
        }
        $refs.Add($raw) | Out-Null
    }

    return @($refs | Select-Object -Unique)
}

function Normalize-Maester {
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

    # Resolve tenant entity ID: prefer real TenantId from tool output; fall back to synthetic.
    $tenantRaw = if ($ToolResult.PSObject.Properties['TenantId'] -and $ToolResult.TenantId) {
        [string]$ToolResult.TenantId
    } else {
        'entra-tenant-configuration'
    }
    $tenantEntityId = (ConvertTo-CanonicalEntityId -RawId $tenantRaw -EntityType 'Tenant').CanonicalId

    foreach ($finding in $ToolResult.Findings) {
        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) {
            [string]$finding.Id
        } else {
            [guid]::NewGuid().ToString()
        }

        $title = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { $finding.Title } else { 'Unknown' }
        $category = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { $finding.Category } else { 'Identity' }

        $rawSev = if ($finding.PSObject.Properties['Severity'] -and $finding.Severity) { $finding.Severity } else { 'Medium' }
        # Word-boundary match so tags like "criticality.info" don't become Critical/High.
        $severity = switch -Regex ($rawSev.ToString().ToLowerInvariant()) {
            '\bcritical\b'                  { 'Critical'; break }
            '\bhigh\b'                      { 'High'; break }
            '\b(medium|moderate)\b'         { 'Medium'; break }
            '\blow\b'                       { 'Low'; break }
            '\b(info|informational)\b'      { 'Info'; break }
            default                         { 'Medium' }
        }

        $compliant = if ($finding.PSObject.Properties['Compliant']) { [bool]$finding.Compliant } else { $true }
        $detail = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { $finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { $finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { $finding.LearnMoreUrl } else { '' }
        $ruleId = if ($finding.PSObject.Properties['TestId'] -and $finding.TestId) { [string]$finding.TestId } else { '' }
        $frameworks = if ($finding.PSObject.Properties['Frameworks'] -and $finding.Frameworks) { @($finding.Frameworks) } else { @() }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Security' }
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else {
            if ($ruleId) { "https://maester.dev/docs/tests/$ruleId" } else { '' }
        }
        $baselineTags = if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) { @(ConvertTo-MaesterStringArray -Value $finding.BaselineTags) } else { @() }
        $mitreTactics = if ($finding.PSObject.Properties['MitreTactics'] -and $finding.MitreTactics) { @(ConvertTo-MaesterStringArray -Value $finding.MitreTactics) } else { @() }
        $mitreTechniques = if ($finding.PSObject.Properties['MitreTechniques'] -and $finding.MitreTechniques) { @(ConvertTo-MaesterStringArray -Value $finding.MitreTechniques) } else { @() }
        $evidenceUris = if ($finding.PSObject.Properties['EvidenceUris'] -and $finding.EvidenceUris) {
            @(ConvertTo-MaesterStringArray -Value $finding.EvidenceUris | Where-Object { $_ -match '^(?i)https://' })
        } else {
            @()
        }
        if (@($evidenceUris).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($learnMore)) {
            $evidenceUris = @($learnMore)
        }
        $remediationSnippets = @()
        if ($finding.PSObject.Properties['RemediationSnippets'] -and $finding.RemediationSnippets) {
            $remediationSnippets = @($finding.RemediationSnippets | ForEach-Object {
                    if ($null -eq $_) { return }
                    if ($_ -is [hashtable]) { return $_ }
                    if ($_ -is [System.Collections.IDictionary]) {
                        $h = @{}
                        foreach ($k in $_.Keys) { $h[[string]$k] = $_[$k] }
                        return $h
                    }
                    $language = [string]$_.language
                    $code = [string]$_.code
                    if ([string]::IsNullOrWhiteSpace($code)) { return }
                    return @{
                        language = if ([string]::IsNullOrWhiteSpace($language)) { 'text' } else { $language }
                        code     = $code
                    }
                })
        }
        $entityRefs = ConvertTo-MaesterEntityRefs -TenantId $tenantRaw -RawRefs $(if ($finding.PSObject.Properties['EntityRefs']) { [string[]]$finding.EntityRefs } else { @() })
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) {
            [string]$finding.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) {
            [string]$ToolResult.ToolVersion
        } else {
            ''
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'maester' -EntityId $tenantEntityId -EntityType 'Tenant' `
            -Title $title -RuleId $ruleId -Compliant ([bool]$compliant) -ProvenanceRunId $runId `
            -Platform 'Entra' -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId '' `
            -Frameworks @($frameworks) -Pillar $pillar -DeepLinkUrl $deepLinkUrl `
            -RemediationSnippets @($remediationSnippets) -EvidenceUris @($evidenceUris) `
            -BaselineTags @($baselineTags) -MitreTactics @($mitreTactics) -MitreTechniques @($mitreTechniques) `
            -EntityRefs @($entityRefs) -ToolVersion $toolVersion
        # Skip null rows (validation failed)
        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
