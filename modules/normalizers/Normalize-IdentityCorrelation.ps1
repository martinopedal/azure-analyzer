#Requires -Version 7.4
<#
.SYNOPSIS
    Normalizer for identity correlator findings.
.DESCRIPTION
    Converts raw identity correlator findings into v2 FindingRow objects
    via New-FindingRow, with canonical entity IDs for User/ServicePrincipal.
#>
[CmdletBinding()]
param ()

. "$PSScriptRoot\..\shared\Schema.ps1"
. "$PSScriptRoot\..\shared\Canonicalize.ps1"

function Get-IdentityCorrelationSeverity {
    param([string] $Severity)
    $raw = if ($Severity) { $Severity } else { 'Info' }
    switch -Regex ($raw.ToLowerInvariant()) {
        'critical' { return 'Critical' }
        '^high$' { return 'High' }
        'medium|moderate' { return 'Medium' }
        '^low$' { return 'Low' }
        'info|informational' { return 'Info' }
        default { return 'Info' }
    }
}

function Get-IdentityCorrelationImpact {
    param([string] $Severity)
    switch ($Severity) {
        'Critical' { return 'High' }
        'High' { return 'High' }
        'Medium' { return 'Medium' }
        default { return 'Low' }
    }
}

function Get-IdentityCorrelationEffort {
    param([string] $Severity)
    switch ($Severity) {
        'Critical' { return 'High' }
        'High' { return 'Medium' }
        'Medium' { return 'Medium' }
        default { return 'Low' }
    }
}

function Get-IdentityCorrelationEntityRefs {
    param(
        [PSCustomObject] $Finding,
        [string] $CanonicalEntityId
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    if ($CanonicalEntityId) { $refs.Add($CanonicalEntityId) | Out-Null }

    if ($Finding.PSObject.Properties['EntityRefs'] -and $Finding.EntityRefs) {
        foreach ($ref in @($Finding.EntityRefs)) {
            if ($ref) { $refs.Add(([string]$ref)) | Out-Null }
        }
    }

    foreach ($prop in @('AppId', 'ObjectId')) {
        if (-not $Finding.PSObject.Properties[$prop] -or -not $Finding.$prop) { continue }
        $id = ([string]$Finding.$prop).ToLowerInvariant()
        if ($id -notmatch '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') { continue }
        $prefix = if ($prop -eq 'AppId') { 'appId' } else { 'objectId' }
        $refs.Add("$prefix`:$id") | Out-Null
    }

    $detail = if ($Finding.PSObject.Properties['Detail']) { [string]$Finding.Detail } else { '' }
    foreach ($match in [regex]::Matches($detail, '(?i)\b(appid|objectid)[:=\s]+([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})')) {
        $refs.Add("$($match.Groups[1].Value.ToLowerInvariant()):$($match.Groups[2].Value.ToLowerInvariant())") | Out-Null
    }

    $seen = @{}
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($ref in $refs) {
        $candidate = [string]$ref
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $ordered.Add($candidate) | Out-Null
    }

    return @($ordered)
}

function Get-IdentityCorrelationDeepLinkUrl {
    param([string[]] $EntityRefs)

    $appRef = @($EntityRefs | Where-Object { $_ -match '^appId:' }) | Select-Object -First 1
    if ($appRef) {
        $appId = $appRef -replace '^appId:', ''
        return "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$appId"
    }

    $objRef = @($EntityRefs | Where-Object { $_ -match '^objectId:' }) | Select-Object -First 1
    if ($objRef) {
        $objId = $objRef -replace '^objectId:', ''
        return "https://entra.microsoft.com/#view/Microsoft_AAD_UsersAndTenants/UserProfileMenuBlade/~/overview/userId/$objId"
    }

    return ''
}

function Get-IdentityCorrelationRemediationSnippets {
    param([string] $Remediation)
    if ([string]::IsNullOrWhiteSpace($Remediation)) {
        return @(
            @{
                language = 'text'
                code     = 'Review correlated identity blast radius and enforce least privilege for linked credentials.'
            }
        )
    }

    return @(
        @{
            language = 'text'
            code     = $Remediation.Trim()
        }
    )
}

function Normalize-IdentityCorrelation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $ToolResult
    )

    if ($ToolResult.Status -ne 'Success' -or -not $ToolResult.Findings) {
        return @()
    }

    $normalized = [System.Collections.Generic.List[PSCustomObject]]::new()
    $runId = if ($ToolResult.PSObject.Properties['RunId'] -and $ToolResult.RunId) { $ToolResult.RunId } else { [guid]::NewGuid().ToString() }

    foreach ($finding in $ToolResult.Findings) {
        if (-not $finding) { continue }

        # Determine EntityType from the finding's PrincipalType (or fall back)
        $entityType = 'ServicePrincipal'
        if ($finding.PSObject.Properties['EntityType'] -and $finding.EntityType) {
            $entityType = [string]$finding.EntityType
        } elseif ($finding.PSObject.Properties['PrincipalType'] -and $finding.PrincipalType) {
            $pt = ([string]$finding.PrincipalType).ToLowerInvariant()
            if ($pt -match 'user') { $entityType = 'User' }
        }

        $rawEntityId = if ($finding.PSObject.Properties['EntityId'] -and $finding.EntityId) { [string]$finding.EntityId } else { '' }
        $canonicalId = $rawEntityId
        if ($rawEntityId) {
            try {
                $canonicalId = (ConvertTo-CanonicalEntityId -RawId $rawEntityId -EntityType $entityType).CanonicalId
            } catch {
                $canonicalId = $rawEntityId.ToLowerInvariant()
            }
        }

        $findingId = if ($finding.PSObject.Properties['Id'] -and $finding.Id) { [string]$finding.Id } else { [guid]::NewGuid().ToString() }
        $title     = if ($finding.PSObject.Properties['Title'] -and $finding.Title) { [string]$finding.Title } else { 'Identity correlation finding' }
        $compliant = if ($finding.PSObject.Properties['Compliant'] -and $null -ne $finding.Compliant) { [bool]$finding.Compliant } else { $false }
        $rawSeverity = if ($finding.PSObject.Properties['Severity']) { [string]$finding.Severity } else { 'Info' }
        $severity  = Get-IdentityCorrelationSeverity -Severity $rawSeverity
        $category  = if ($finding.PSObject.Properties['Category'] -and $finding.Category) { [string]$finding.Category } else { 'Identity' }
        $detail    = if ($finding.PSObject.Properties['Detail'] -and $finding.Detail) { [string]$finding.Detail } else { '' }
        $remediation = if ($finding.PSObject.Properties['Remediation'] -and $finding.Remediation) { [string]$finding.Remediation } else { '' }
        $learnMore = if ($finding.PSObject.Properties['LearnMoreUrl'] -and $finding.LearnMoreUrl) { [string]$finding.LearnMoreUrl } else { '' }
        $resourceId = if ($finding.PSObject.Properties['ResourceId'] -and $finding.ResourceId) { [string]$finding.ResourceId } else { '' }
        $frameworks = if ($finding.PSObject.Properties['Frameworks'] -and $finding.Frameworks) {
            @($finding.Frameworks)
        } else {
            @(
                @{ Name = 'NIST 800-53'; Controls = @('AC-2', 'AC-6', 'IA-5') },
                @{ Name = 'CIS Controls v8'; Controls = @('5.3', '6.3', '6.7') }
            )
        }
        $pillar = if ($finding.PSObject.Properties['Pillar'] -and $finding.Pillar) { [string]$finding.Pillar } else { 'Security' }
        $impact = if ($finding.PSObject.Properties['Impact'] -and $finding.Impact) { [string]$finding.Impact } else { Get-IdentityCorrelationImpact -Severity $severity }
        $effort = if ($finding.PSObject.Properties['Effort'] -and $finding.Effort) { [string]$finding.Effort } else { Get-IdentityCorrelationEffort -Severity $severity }
        $entityRefs = Get-IdentityCorrelationEntityRefs -Finding $finding -CanonicalEntityId $canonicalId
        $deepLinkUrl = if ($finding.PSObject.Properties['DeepLinkUrl'] -and $finding.DeepLinkUrl) { [string]$finding.DeepLinkUrl } else { Get-IdentityCorrelationDeepLinkUrl -EntityRefs $entityRefs }
        $remediationSnippets = if ($finding.PSObject.Properties['RemediationSnippets'] -and $finding.RemediationSnippets) {
            @($finding.RemediationSnippets)
        } else {
            Get-IdentityCorrelationRemediationSnippets -Remediation $remediation
        }
        $evidenceUris = [System.Collections.Generic.List[string]]::new()
        if ($finding.PSObject.Properties['EvidenceUris'] -and $finding.EvidenceUris) {
            foreach ($uri in @($finding.EvidenceUris)) { if ($uri) { $evidenceUris.Add(([string]$uri)) | Out-Null } }
        }
        if ($learnMore -and $learnMore -match '^https://') { $evidenceUris.Add($learnMore) | Out-Null }
        if ($deepLinkUrl -and $deepLinkUrl -match '^https://') { $evidenceUris.Add($deepLinkUrl) | Out-Null }
        $baselineTags = if ($finding.PSObject.Properties['BaselineTags'] -and $finding.BaselineTags) {
            @($finding.BaselineTags | ForEach-Object { [string]$_ })
        } else {
            @('identity-correlator', 'attack-path-correlation', ("category/{0}" -f $category.ToLowerInvariant().Replace(' ', '-')))
        }
        $mitreTactics = if ($finding.PSObject.Properties['MitreTactics'] -and $finding.MitreTactics) {
            @($finding.MitreTactics | ForEach-Object { [string]$_ })
        } else {
            @('TA0001', 'TA0006', 'TA0008')
        }
        $mitreTechniques = if ($finding.PSObject.Properties['MitreTechniques'] -and $finding.MitreTechniques) {
            @($finding.MitreTechniques | ForEach-Object { [string]$_ })
        } else {
            @('T1078', 'T1550', 'T1021')
        }
        $toolVersion = if ($finding.PSObject.Properties['ToolVersion'] -and $finding.ToolVersion) {
            [string]$finding.ToolVersion
        } elseif ($ToolResult.PSObject.Properties['ToolVersion'] -and $ToolResult.ToolVersion) {
            [string]$ToolResult.ToolVersion
        } else {
            'identity-correlator'
        }

        $row = New-FindingRow -Id $findingId `
            -Source 'identity-correlator' -EntityId $canonicalId -EntityType $entityType `
            -Title $title -Compliant $compliant -ProvenanceRunId $runId `
            -Category $category -Severity $severity `
            -Detail $detail -Remediation $remediation `
            -LearnMoreUrl $learnMore -ResourceId $resourceId `
            -Frameworks $frameworks -Pillar $pillar -Impact $impact -Effort $effort `
            -DeepLinkUrl $deepLinkUrl -RemediationSnippets $remediationSnippets `
            -EvidenceUris @($evidenceUris) -BaselineTags $baselineTags `
            -MitreTactics $mitreTactics -MitreTechniques $mitreTechniques `
            -EntityRefs $entityRefs -ToolVersion $toolVersion

        if ($null -ne $row) {
            $normalized.Add($row)
        }
    }

    return @($normalized)
}
