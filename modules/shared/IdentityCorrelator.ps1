#Requires -Version 7.4
<#
.SYNOPSIS
    Cross-dimensional identity correlation engine.
.DESCRIPTION
    Scans the entity store for service principals, managed identities, and app
    registrations that appear across multiple dimensions (Azure, Entra, GitHub,
    ADO). Uses candidate reduction -- never bulk-enumerates SPNs.
    Optionally enriches with Graph federated identity credential lookups when
    -IncludeGraphLookup is set and Microsoft.Graph is connected.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Schema.ps1"
. "$PSScriptRoot\Sanitize.ps1"
. "$PSScriptRoot\Retry.ps1"

function Get-IdentityCandidatesFromStore {
    <#
    .SYNOPSIS
        Extract identity candidates from the entity store without bulk enumeration.
    .DESCRIPTION
        Scans entities and their observations for appIds, objectIds, SPN names,
        and display names that reference identities. Groups references by a
        candidate key (preferring appId, falling back to objectId or name).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $EntityStore
    )

    # candidateKey -> hashtable with Keys: AppId, ObjectId, DisplayName, Dimensions (hashtable dim->evidence[])
    $candidates = @{}

    $entities = if ($EntityStore -is [System.Collections.IEnumerable] -and $EntityStore -isnot [string]) {
        @($EntityStore)
    } elseif ($EntityStore.PSObject.Methods['GetEntities']) {
        @($EntityStore.GetEntities())
    } else {
        @()
    }

    foreach ($entity in $entities) {
        if (-not $entity) { continue }

        $entityType = $null
        if ($entity.PSObject.Properties['EntityType']) { $entityType = $entity.EntityType }
        $platform = $null
        if ($entity.PSObject.Properties['Platform']) { $platform = $entity.Platform }
        $entityId = $null
        if ($entity.PSObject.Properties['EntityId']) { $entityId = $entity.EntityId }
        $displayName = $null
        if ($entity.PSObject.Properties['DisplayName']) { $displayName = $entity.DisplayName }

        $isIdentityEntity = $entityType -in @('ServicePrincipal', 'ManagedIdentity', 'Application')

        # Extract appId / objectId from ExternalIds if present
        $appId = $null
        $objectId = $null
        if ($entity.PSObject.Properties['ExternalIds'] -and $entity.ExternalIds) {
            foreach ($extId in @($entity.ExternalIds)) {
                if (-not $extId) { continue }
                $extPlatform = $null
                if ($extId.PSObject.Properties['Platform']) { $extPlatform = $extId.Platform }
                $extIdValue = $null
                if ($extId.PSObject.Properties['Id']) { $extIdValue = $extId.Id }

                if ($extPlatform -eq 'Entra' -and $extIdValue) {
                    if ($extIdValue -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') {
                        if (-not $objectId) { $objectId = $extIdValue }
                    }
                }
                if ($extPlatform -eq 'EntraApp' -and $extIdValue) {
                    $appId = $extIdValue
                }
            }
        }

        # Also scan entity ID for GUID patterns (e.g. SPN entity IDs)
        if ($isIdentityEntity -and $entityId -and -not $appId) {
            if ($entityId -match '([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})') {
                if (-not $objectId) { $objectId = $Matches[1] }
            }
        }

        # Scan observations for identity references
        $observations = @()
        if ($entity.PSObject.Properties['Observations'] -and $entity.Observations) {
            $observations = @($entity.Observations)
        }

        foreach ($obs in $observations) {
            if (-not $obs) { continue }

            $obsDetail = $null
            if ($obs.PSObject.Properties['Detail']) { $obsDetail = $obs.Detail }
            $obsTitle = $null
            if ($obs.PSObject.Properties['Title']) { $obsTitle = $obs.Title }
            $obsSource = $null
            if ($obs.PSObject.Properties['Source']) { $obsSource = $obs.Source }
            $obsPlatform = $null
            if ($obs.PSObject.Properties['Platform']) { $obsPlatform = $obs.Platform }
            $obsResourceId = $null
            if ($obs.PSObject.Properties['ResourceId']) { $obsResourceId = $obs.ResourceId }

            # Extract appId from observation details (RBAC findings, service connection data)
            $detailText = @($obsDetail, $obsTitle, $obsResourceId) -join ' '
            if ($detailText -match 'appId[:\s=]+([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})') {
                if (-not $appId) { $appId = $Matches[1] }
            }
            if ($detailText -match 'objectId[:\s=]+([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})') {
                if (-not $objectId) { $objectId = $Matches[1] }
            }
        }

        # Build candidate key: prefer appId, then objectId, then displayName
        $candidateKey = $null
        if ($appId) {
            $candidateKey = "app:$appId"
        } elseif ($objectId) {
            $candidateKey = "obj:$objectId"
        } elseif ($isIdentityEntity -and $displayName) {
            $candidateKey = "name:$($displayName.ToLowerInvariant())"
        }

        if (-not $candidateKey) { continue }

        # Ensure candidate entry exists
        if (-not $candidates.ContainsKey($candidateKey)) {
            $candidates[$candidateKey] = @{
                AppId                 = $appId
                ObjectId              = $objectId
                DisplayName           = $displayName
                Dimensions            = @{}
                HasPrivilegedAzureRole = $false
                HasPatBasedAdoAuth    = $false
                CiEvidenceCount       = 0
            }
        }

        $candidate = $candidates[$candidateKey]

        # Update IDs if we found better ones
        if ($appId -and -not $candidate.AppId) { $candidate.AppId = $appId }
        if ($objectId -and -not $candidate.ObjectId) { $candidate.ObjectId = $objectId }
        if ($displayName -and -not $candidate.DisplayName) { $candidate.DisplayName = $displayName }

        # Determine dimension from platform
        $dimension = $null
        if ($platform) { $dimension = $platform }
        if (-not $dimension -and $isIdentityEntity) { $dimension = 'Entra' }

        if ($dimension) {
            if (-not $candidate.Dimensions.ContainsKey($dimension)) {
                $candidate.Dimensions[$dimension] = [System.Collections.Generic.List[string]]::new()
            }

            $evidence = "Entity: $entityType"
            if ($entityId) { $evidence += " ($entityId)" }
            $candidate.Dimensions[$dimension].Add($evidence)
        }

        # Also count observations by their platform/source as evidence in other dimensions
        foreach ($obs in $observations) {
            if (-not $obs) { continue }
            $obsPlatform = $null
            if ($obs.PSObject.Properties['Platform']) { $obsPlatform = $obs.Platform }
            $obsTitle = ''
            if ($obs.PSObject.Properties['Title']) { $obsTitle = $obs.Title }
            $obsSource = ''
            if ($obs.PSObject.Properties['Source']) { $obsSource = $obs.Source }
            $obsDetail = ''
            if ($obs.PSObject.Properties['Detail']) { $obsDetail = $obs.Detail }
            $signalText = @($obsTitle, $obsDetail) -join ' '
            if ($obsPlatform -eq 'Azure' -and $signalText -match '(?i)\b(owner|contributor)\b') {
                $candidate.HasPrivilegedAzureRole = $true
            }
            if ($obsPlatform -eq 'ADO' -and $signalText -match '(?i)\b(AuthScheme=Token|pat|personal access token)\b') {
                $candidate.HasPatBasedAdoAuth = $true
            }
            if ($obsPlatform -in @('ADO', 'GitHub')) {
                $candidate.CiEvidenceCount += 1
            }

            if ($obsPlatform -and $obsPlatform -ne $dimension) {
                if (-not $candidate.Dimensions.ContainsKey($obsPlatform)) {
                    $candidate.Dimensions[$obsPlatform] = [System.Collections.Generic.List[string]]::new()
                }
                $evidenceText = "Finding: $obsSource - $obsTitle"
                if ($obsDetail) { $evidenceText += " | $obsDetail" }
                $candidate.Dimensions[$obsPlatform].Add($evidenceText)
            }
        }
    }

    return $candidates
}

function Merge-CandidateAliases {
    <#
    .SYNOPSIS
        Merge candidate entries that share an objectId↔appId alias.
    .DESCRIPTION
        When one entity is keyed by objectId and another by appId but they refer
        to the same identity, this merges them into a single candidate keyed by
        appId. Also checks observation text for cross-references between the two
        ID types to discover aliases without Graph.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable] $Candidates
    )

    # Build alias map: objectId → appId from candidates that have both
    $aliases = @{}
    foreach ($key in @($Candidates.Keys)) {
        $c = $Candidates[$key]
        if ($c.AppId -and $c.ObjectId) {
            $aliases[$c.ObjectId] = $c.AppId
        }
    }

    # Also scan obj:-keyed candidates for appId references in their dimension evidence
    foreach ($key in @($Candidates.Keys)) {
        if (-not $key.StartsWith('obj:')) { continue }
        $c = $Candidates[$key]
        $objId = $key.Substring(4)
        if ($aliases.ContainsKey($objId)) { continue }

        # Check if any evidence text mentions an appId
        foreach ($dim in $c.Dimensions.Keys) {
            foreach ($ev in @($c.Dimensions[$dim])) {
                if ($ev -match 'appId[:\s=]+([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})') {
                    $aliases[$objId] = $Matches[1]
                    $c.AppId = $Matches[1]
                    break
                }
            }
            if ($aliases.ContainsKey($objId)) { break }
        }
    }

    # Merge obj:-keyed candidates into their app:-keyed counterpart
    foreach ($objId in @($aliases.Keys)) {
        $appId = $aliases[$objId]
        $objKey = "obj:$objId"
        $appKey = "app:$appId"

        if (-not $Candidates.ContainsKey($objKey)) { continue }

        $objCandidate = $Candidates[$objKey]

        if ($Candidates.ContainsKey($appKey)) {
            # Merge into existing app-keyed candidate
            $appCandidate = $Candidates[$appKey]
            if (-not $appCandidate.ObjectId -and $objCandidate.ObjectId) {
                $appCandidate.ObjectId = $objCandidate.ObjectId
            }
            if (-not $appCandidate.DisplayName -and $objCandidate.DisplayName) {
                $appCandidate.DisplayName = $objCandidate.DisplayName
            }

            foreach ($dim in $objCandidate.Dimensions.Keys) {
                if (-not $appCandidate.Dimensions.ContainsKey($dim)) {
                    $appCandidate.Dimensions[$dim] = [System.Collections.Generic.List[string]]::new()
                }
                foreach ($ev in @($objCandidate.Dimensions[$dim])) {
                    $appCandidate.Dimensions[$dim].Add($ev)
                }
            }
        } else {
            # Re-key the obj candidate as an app candidate
            $objCandidate.AppId = $appId
            $Candidates[$appKey] = $objCandidate
        }

        $Candidates.Remove($objKey)
    }

    return $Candidates
}

function Get-FederatedCredentials {
    <#
    .SYNOPSIS
        Look up federated identity credentials for a candidate app via Microsoft Graph.
    .DESCRIPTION
        Requires Microsoft.Graph to be connected. Uses Invoke-WithRetry for resilience.
        Returns federated credential objects or $null on failure.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $AppId
    )

    try {
        $app = Invoke-WithRetry -ScriptBlock {
            Get-MgApplication -Filter "appId eq '$AppId'" -ErrorAction Stop
        }
        if (-not $app) { return $null }

        $appObjectId = $null
        if ($app -is [System.Collections.IEnumerable] -and $app -isnot [string]) {
            $first = @($app)[0]
            if ($first.PSObject.Properties['Id']) { $appObjectId = $first.Id }
        } else {
            if ($app.PSObject.Properties['Id']) { $appObjectId = $app.Id }
        }

        if (-not $appObjectId) { return $null }

        $creds = Invoke-WithRetry -ScriptBlock {
            Get-MgApplicationFederatedIdentityCredential -ApplicationId $appObjectId -ErrorAction Stop
        }
        return $creds
    } catch {
        $sanitized = Remove-Credentials -Text $_.Exception.Message
        Write-Warning "Graph lookup failed for appId '$AppId': $sanitized"
        return $null
    }
}

function Get-ConfidenceLevel {
    <#
    .SYNOPSIS
        Determine confidence based on dimension count and evidence type.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [int] $DimensionCount,

        [Parameter(Mandatory)]
        [bool] $IsNameBasedOnly
    )

    # Map to schema v2 ConfidenceLevels: Confirmed, Likely, Unconfirmed, Unknown
    if ($IsNameBasedOnly) { return 'Unconfirmed' }
    if ($DimensionCount -ge 3) { return 'Confirmed' }
    if ($DimensionCount -ge 2) { return 'Likely' }
    return 'Unconfirmed'
}

function New-CorrelationRiskFinding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $RunId,
        [Parameter(Mandatory)]
        [string] $EntityId,
        [Parameter(Mandatory)]
        [string] $Title,
        [Parameter(Mandatory)]
        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')]
        [string] $Severity,
        [Parameter(Mandatory)]
        [string] $Detail,
        [int] $EvidenceCount = 0
    )

    return (New-FindingRow `
        -Id ([guid]::NewGuid().ToString()) `
        -Source 'identity-correlator' `
        -EntityId $EntityId `
        -EntityType 'ServicePrincipal' `
        -Title $Title `
        -Compliant $false `
        -ProvenanceRunId $RunId `
        -Platform 'Entra' `
        -Category 'Identity Correlation Risk' `
        -Severity $Severity `
        -Detail $Detail `
        -Confidence 'Likely' `
        -EvidenceCount $EvidenceCount)
}

function Invoke-IdentityCorrelation {
    <#
    .SYNOPSIS
        Main entry point for cross-dimensional identity correlation.
    .DESCRIPTION
        Scans the entity store for candidates, correlates across dimensions,
        and returns findings as v3 FindingRow objects.
    .PARAMETER EntityStore
        The populated entity store (EntityStore class instance or entity array).
    .PARAMETER TenantId
        Azure AD tenant ID for scoping.
    .PARAMETER IncludeGraphLookup
        When set, enriches candidates with Graph federated identity credentials.
        Requires Microsoft.Graph to be connected with Security Reader permissions.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $EntityStore,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TenantId,

        [switch] $IncludeGraphLookup
    )

    $runId = [guid]::NewGuid().ToString()
    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Phase 1: Extract candidates from entity store
    $candidates = Get-IdentityCandidatesFromStore -EntityStore $EntityStore

    if ($candidates.Count -eq 0) {
        Write-Verbose 'IdentityCorrelator: No identity candidates found in entity store.'
        return @()
    }

    # Phase 1b: Merge candidates sharing objectId↔appId aliases
    $candidates = Merge-CandidateAliases -Candidates $candidates

    Write-Verbose "IdentityCorrelator: Found $($candidates.Count) identity candidate(s) after alias merge."

    # Check Graph availability for optional enrichment
    $graphAvailable = $false
    if ($IncludeGraphLookup) {
        $mgCmd = Get-Command -Name 'Get-MgApplication' -ErrorAction SilentlyContinue
        if ($mgCmd) {
            $graphAvailable = $true
            Write-Verbose 'IdentityCorrelator: Graph module available, will enrich candidates.'
        } else {
            Write-Warning 'IdentityCorrelator: -IncludeGraphLookup set but Microsoft.Graph is not available. Skipping Graph enrichment.'
        }
    }

    $allDimensions = @('Azure', 'Entra', 'GitHub', 'ADO')

    foreach ($candidateKey in $candidates.Keys) {
        $candidate = $candidates[$candidateKey]
        $dimCount = $candidate.Dimensions.Count

        # Only emit findings for candidates found in 2+ dimensions or enriched via Graph
        $graphEnriched = $false
        if ($graphAvailable -and $candidate.AppId) {
            $fedCreds = Get-FederatedCredentials -AppId $candidate.AppId
            if ($fedCreds) {
                foreach ($cred in @($fedCreds)) {
                    $subject = $null
                    if ($cred.PSObject.Properties['Subject']) { $subject = $cred.Subject }
                    $issuer = $null
                    if ($cred.PSObject.Properties['Issuer']) { $issuer = $cred.Issuer }

                    # Determine dimension from federated credential subject/issuer
                    if ($subject -and $subject -match 'repo:') {
                        if (-not $candidate.Dimensions.ContainsKey('GitHub')) {
                            $candidate.Dimensions['GitHub'] = [System.Collections.Generic.List[string]]::new()
                        }
                        $candidate.Dimensions['GitHub'].Add("FederatedCredential: $subject")
                        $graphEnriched = $true
                    }
                    if ($issuer -and $issuer -match 'vstoken\.dev\.azure\.com') {
                        if (-not $candidate.Dimensions.ContainsKey('ADO')) {
                            $candidate.Dimensions['ADO'] = [System.Collections.Generic.List[string]]::new()
                        }
                        $candidate.Dimensions['ADO'].Add("FederatedCredential: $subject")
                        $graphEnriched = $true
                    }
                }
            }
        }

        $dimCount = $candidate.Dimensions.Count
        if ($dimCount -lt 2) { continue }

        $isNameBased = $candidateKey.StartsWith('name:')
        $confidence = Get-ConfidenceLevel -DimensionCount $dimCount -IsNameBasedOnly $isNameBased

        $displayName = $candidate.DisplayName
        if (-not $displayName) { $displayName = $candidate.AppId ?? $candidate.ObjectId ?? 'Unknown' }

        $dimensionNames = @($candidate.Dimensions.Keys | Sort-Object)
        $missingDims = @($allDimensions | Where-Object { $dimensionNames -notcontains $_ })

        $evidenceCount = 0
        foreach ($dim in $dimensionNames) {
            $evidenceCount += $candidate.Dimensions[$dim].Count
        }

        # Build detail string
        $detailParts = [System.Collections.Generic.List[string]]::new()
        if ($candidate.AppId) { $detailParts.Add("AppId: $($candidate.AppId)") }
        if ($candidate.ObjectId) { $detailParts.Add("ObjectId: $($candidate.ObjectId)") }
        foreach ($dim in $dimensionNames) {
            $evidenceList = $candidate.Dimensions[$dim] -join '; '
            $detailParts.Add("$dim`: $evidenceList")
        }
        if ($graphEnriched) { $detailParts.Add('Enriched via Graph federated identity credentials') }
        $detail = $detailParts -join ' | '

        $entityId = if ($candidate.AppId) {
            "appId:$($candidate.AppId.ToLowerInvariant())"
        } elseif ($candidate.ObjectId) {
            "objectId:$($candidate.ObjectId.ToLowerInvariant())"
        } else {
            "spn/$($displayName.ToLowerInvariant() -replace '[^a-z0-9-]', '-')"
        }

        $title = "SPN $displayName spans $($dimensionNames -join ', ')"

        $row = New-FindingRow `
            -Id ([guid]::NewGuid().ToString()) `
            -Source 'identity-correlator' `
            -EntityId $entityId `
            -EntityType 'ServicePrincipal' `
            -Title $title `
            -Compliant $true `
            -ProvenanceRunId $runId `
            -Platform 'Entra' `
            -Category 'Identity Correlation' `
            -Severity 'Info' `
            -Detail $detail `
            -Confidence $confidence `
            -EvidenceCount $evidenceCount `
            -MissingDimensions $missingDims

        $findings.Add($row)

        $hasPrivilegedAzureRole = [bool]$candidate.HasPrivilegedAzureRole
        if (-not $hasPrivilegedAzureRole -and $candidate.Dimensions.ContainsKey('Azure')) {
            foreach ($ev in @($candidate.Dimensions['Azure'])) {
                if ($ev -match '(?i)\b(owner|contributor)\b') {
                    $hasPrivilegedAzureRole = $true
                    break
                }
            }
        }
        $isCiIdentity = $dimensionNames -contains 'GitHub' -or $dimensionNames -contains 'ADO'
        if ($hasPrivilegedAzureRole -and $isCiIdentity) {
            $findings.Add((New-CorrelationRiskFinding `
                -RunId $runId `
                -EntityId $entityId `
                -Title "Privileged SPN $displayName is used by CI/CD identity chain" `
                -Severity 'High' `
                -Detail "Identity has Azure Owner/Contributor evidence and is linked to CI/CD dimensions ($($dimensionNames -join ', '))." `
                -EvidenceCount $evidenceCount))
        }

        $hasPatBasedAuth = [bool]$candidate.HasPatBasedAdoAuth
        if (-not $hasPatBasedAuth -and $candidate.Dimensions.ContainsKey('ADO')) {
            foreach ($ev in @($candidate.Dimensions['ADO'])) {
                if ($ev -match '(?i)\b(AuthScheme=Token|pat|personal access token)\b') {
                    $hasPatBasedAuth = $true
                    break
                }
            }
        }
        if ($hasPatBasedAuth) {
            $findings.Add((New-CorrelationRiskFinding `
                -RunId $runId `
                -EntityId $entityId `
                -Title "SPN $displayName is linked to PAT-based ADO service connection" `
                -Severity 'Medium' `
                -Detail 'ADO evidence indicates token/PAT authentication. Prefer workload identity federation where possible.' `
                -EvidenceCount $evidenceCount))
        }

        $ciBindings = [int]$candidate.CiEvidenceCount
        if ($candidate.Dimensions.ContainsKey('GitHub')) { $ciBindings += @($candidate.Dimensions['GitHub']).Count }
        if ($candidate.Dimensions.ContainsKey('ADO')) { $ciBindings += @($candidate.Dimensions['ADO']).Count }
        if ($ciBindings -gt 1) {
            $findings.Add((New-CorrelationRiskFinding `
                -RunId $runId `
                -EntityId $entityId `
                -Title "SPN $displayName is reused across multiple CI/CD bindings" `
                -Severity 'Medium' `
                -Detail "Detected $ciBindings CI/CD evidences (GitHub + ADO). Consider reducing identity reuse and scope." `
                -EvidenceCount $ciBindings))
        }
    }

    Write-Verbose "IdentityCorrelator: Emitted $($findings.Count) correlation finding(s)."
    return @($findings)
}
