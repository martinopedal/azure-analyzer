#Requires -Version 7.4
<#
.SYNOPSIS
    Schema v2 factories and validation helpers.
.DESCRIPTION
    Provides constructors for finding rows and entity stubs, plus validation
    functions that return boolean pass/fail results with detailed errors.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SchemaVersion = '2.2'
# FindingRow v2.2 (additive, back-compat with v2.1):
#   * Adds 13 optional fields populated by the per-tool ETL closures
#     (#300-#313): Frameworks (now first-class with hashtable shape),
#     Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets,
#     EvidenceUris, BaselineTags, ScoreDelta, MitreTactics,
#     MitreTechniques, EntityRefs, ToolVersion. All zero-value defaults.
#     No enum tightening, no rename, no behaviour change for existing
#     callers.
# FindingRow v2.1 (additive, back-compat with v2.0):
#   * Adds optional RuleId field (default '') for stable rule identification
#     used by the HTML collapsible-tree level-3 grouping, framework mapping
#     (RuleIdPrefix), and downstream rule-quality dashboards.
#   * Adds AdoProject and KarpenterProvisioner to the EntityType enum.
# Schema bump: entities.json moves from a bare array (v3.0) to an object
# { SchemaVersion: '3.1', Entities: [...], Edges: [...] } when edges are present.
# Readers must support both shapes (back-compat).
$script:EntitiesFileSchemaVersion = '3.1'
$script:SeverityLevels = @('Critical', 'High', 'Medium', 'Low', 'Info')
# Edge.Relation enum. Add new values as discovery surfaces grow.
$script:EdgeRelations = @(
    'GuestOf',            # User -> Tenant (B2B home tenant)
    'MemberOf',           # User|ServicePrincipal -> Group/role
    'HasRoleOn',          # ServicePrincipal|User -> AzureResource (RBAC)
    'OwnsAppRegistration',# User|ServicePrincipal -> Application
    'ConsentedTo'         # User|ServicePrincipal -> Application (delegated/admin consent)
)
$script:EntityTypes = @(
    'AzureResource',
    'ServicePrincipal',
    'ManagedIdentity',
    'Application',
    'Repository',
    'IaCFile',
    'BuildDefinition',
    'ReleaseDefinition',
    'Pipeline',
    'VariableGroup',
    'Environment',
    'ServiceConnection',
    'User',
    'Subscription',
    'ManagementGroup',
    'Workflow',
    'Tenant',
    'AdoProject',
    'KarpenterProvisioner'
)
$script:Platforms = @('Azure', 'Entra', 'GitHub', 'ADO', 'AzureDevOps', 'IaC')
$script:ConfidenceLevels = @('Confirmed', 'Likely', 'Unconfirmed', 'Unknown')
$script:ValidationFailures = [System.Collections.Generic.List[PSCustomObject]]::new()

# Validation failure tracking
$script:ValidationFailures = [System.Collections.Generic.List[PSCustomObject]]::new()

function Get-SchemaValidationFailures {
    <#
    .SYNOPSIS
        Retrieve logged validation failures.
    .DESCRIPTION
        Returns a list of validation failures logged during FindingRow construction.
    #>
    return ,$script:ValidationFailures.ToArray()
}

function Reset-SchemaValidationFailures {
    <#
    .SYNOPSIS
        Clear validation failure log.
    .DESCRIPTION
        Clears the internal list of validation failures.
    #>
    $script:ValidationFailures.Clear()
}

function Get-PlatformForEntityType {
    param (
        [Parameter(Mandatory)]
        [ValidateSet(
            'AzureResource',
            'ServicePrincipal',
            'ManagedIdentity',
            'Application',
            'Repository',
            'IaCFile',
            'BuildDefinition',
            'ReleaseDefinition',
            'Pipeline',
            'VariableGroup',
            'Environment',
            'ServiceConnection',
            'User',
            'Subscription',
            'ManagementGroup',
            'Workflow',
            'Tenant',
            'AdoProject',
            'KarpenterProvisioner'
        )]
        [string] $EntityType
    )

    switch ($EntityType) {
        'AzureResource' { 'Azure' }
        'ManagedIdentity' { 'Azure' }
        'Subscription' { 'Azure' }
        'ManagementGroup' { 'Azure' }
        'KarpenterProvisioner' { 'Azure' }
        'ServicePrincipal' { 'Entra' }
        'Application' { 'Entra' }
        'User' { 'Entra' }
        'Tenant' { 'Entra' }
        'Repository' { 'GitHub' }
        'IaCFile' { 'IaC' }
        'BuildDefinition' { 'AzureDevOps' }
        'ReleaseDefinition' { 'AzureDevOps' }
        'Workflow' { 'GitHub' }
        'Pipeline' { 'ADO' }
        'VariableGroup' { 'ADO' }
        'Environment' { 'ADO' }
        'ServiceConnection' { 'ADO' }
        'AdoProject' { 'ADO' }
        default { throw "Unknown EntityType '$EntityType'." }
    }
}

function Get-SchemaValidationFailures {
    <#
    .SYNOPSIS
        Retrieve the list of schema validation failures recorded during the current session.
    .DESCRIPTION
        Returns an array of PSCustomObjects with Source, Error, Timestamp.
    #>
    [CmdletBinding()]
    param ()
    return $script:ValidationFailures.ToArray()
}

function Reset-SchemaValidationFailures {
    <#
    .SYNOPSIS
        Clear all recorded schema validation failures.
    #>
    [CmdletBinding()]
    param ()
    $script:ValidationFailures.Clear()
}

function New-FindingRow {
    <#
    .SYNOPSIS
        Create a schema v2 finding row with required and optional fields.
    .DESCRIPTION
        Initializes all known fields. Required fields are validated and
        canonical platform metadata is inferred when omitted.
    .PARAMETER Id
        Finding identifier (GUID or tool-provided ID).
    .PARAMETER Source
        Tool source key (e.g., azqr, psrule).
    .PARAMETER EntityId
        Canonical entity identifier.
    .PARAMETER EntityType
        Entity type enum.
    .PARAMETER Title
        Human-readable title of the finding.
    .PARAMETER RuleId
        Stable identifier of the rule that produced the finding (e.g.
        'Azure.KeyVault.SoftDelete', 'finops-appserviceplan-idle-cpu',
        'MT.1010'). Optional; defaults to ''. When supplied, the HTML report
        collapsible tree uses it as the level-3 grouping key (#275, #229) and
        framework mapping (RuleIdPrefix) keys off it. Added in v2.1.
    .PARAMETER Compliant
        Boolean compliance status.
    .PARAMETER ProvenanceRunId
        Run identifier for the tool execution.
    .NOTES
        Schema v2.1 (additive, back-compat with v2.0):
          * RuleId field added (optional, default '').
          * EntityType enum extended with AdoProject + KarpenterProvisioner.
        Existing callers continue to work unchanged.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Id,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Source,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $EntityId,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $EntityType,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Title,

        [string] $RuleId = '',

        [Parameter(Mandatory)]
        [object] $Compliant,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProvenanceRunId,

        [string] $Category,
        [string] $Severity,
        [string] $Detail,
        [string] $Remediation,
        [string] $ResourceId,
        [string] $LearnMoreUrl,
        [string] $Platform,
        [string] $SubscriptionId,
        [string] $SubscriptionName,
        [string] $ResourceGroup,
        [string[]] $ManagementGroupPath,
        [object[]] $Frameworks,
        [string[]] $Controls,
        [string] $Confidence,
        [int] $EvidenceCount,
        [string[]] $MissingDimensions,
        [string] $ProvenanceSource,
        [string] $ProvenanceRawRecordRef,
        [datetime] $ProvenanceTimestamp,

        # --- Schema 2.2 additive fields (#299) ---
        # All optional with zero-value defaults; populated by per-tool ETL
        # closures (#300-#313). No behaviour change for callers that omit them.
        [string] $Pillar = '',
        [string] $Impact = '',
        [string] $Effort = '',
        [string] $DeepLinkUrl = '',
        [hashtable[]] $RemediationSnippets = @(),
        [string[]] $EvidenceUris = @(),
        [string[]] $BaselineTags = @(),
        [Nullable[double]] $ScoreDelta = $null,
        [string[]] $MitreTactics = @(),
        [string[]] $MitreTechniques = @(),
        [string[]] $EntityRefs = @(),
        [string] $ToolVersion = '',

        [string] $SchemaVersion = $script:SchemaVersion
    )

    $preValidationErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($required in @(
            @{ Name = 'Id'; Value = $Id },
            @{ Name = 'Source'; Value = $Source },
            @{ Name = 'EntityId'; Value = $EntityId },
            @{ Name = 'EntityType'; Value = $EntityType },
            @{ Name = 'Title'; Value = $Title },
            @{ Name = 'ProvenanceRunId'; Value = $ProvenanceRunId }
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
            $preValidationErrors.Add("Required parameter '$($required.Name)' is missing or empty.")
        }
    }

    if ($EntityType -and $EntityType -notin $script:EntityTypes) {
        $preValidationErrors.Add("EntityType '$EntityType' is not valid. Valid types: $($script:EntityTypes -join ', ').")
    }
    if ($Severity -and $Severity -notin $script:SeverityLevels) {
        $preValidationErrors.Add("Severity '$Severity' is not valid. Valid levels: $($script:SeverityLevels -join ', ').")
    }
    if ($Platform -and $Platform -notin $script:Platforms) {
        $preValidationErrors.Add("Platform '$Platform' is not valid. Valid platforms: $($script:Platforms -join ', ').")
    }
    if ($Confidence -and $Confidence -notin $script:ConfidenceLevels) {
        $preValidationErrors.Add("Confidence '$Confidence' is not valid. Valid confidence levels: $($script:ConfidenceLevels -join ', ').")
    }

    if ($null -eq $Compliant) {
        $preValidationErrors.Add("Required parameter 'Compliant' is missing.")
    } elseif ($Compliant -isnot [bool]) {
        $preValidationErrors.Add("Compliant must be a boolean value, got '$($Compliant.GetType().Name)'.")
    }

    if ($preValidationErrors.Count -gt 0) {
        $sourceForLog = if ([string]::IsNullOrWhiteSpace([string]$Source)) { 'unknown' } else { $Source }
        $sanitizedError = if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
            Remove-Credentials ($preValidationErrors -join '; ')
        } else {
            $preValidationErrors -join '; '
        }

        $script:ValidationFailures.Add([PSCustomObject]@{
                Source    = $sourceForLog
                Error     = $sanitizedError
                Timestamp = Get-Date
            })
        Write-Warning "FindingRow validation failed [$sourceForLog]: $sanitizedError"
        return $null
    }

    $resolvedPlatform = if ($Platform) { $Platform } else { Get-PlatformForEntityType -EntityType $EntityType }
    $provenance = [PSCustomObject]@{
        RunId        = $ProvenanceRunId
        Source       = if ($ProvenanceSource) { $ProvenanceSource } else { $Source }
        RawRecordRef = $ProvenanceRawRecordRef
        Timestamp    = if ($ProvenanceTimestamp) { $ProvenanceTimestamp.ToUniversalTime().ToString('o') } else { (Get-Date).ToUniversalTime().ToString('o') }
    }

    $row = [PSCustomObject]@{
        Id               = $Id
        Source           = $Source
        Category         = $Category
        Title            = $Title
        RuleId           = $RuleId
        Severity         = $Severity
        Compliant        = [bool]$Compliant
        Detail           = $Detail
        Remediation      = $Remediation
        ResourceId       = $ResourceId
        LearnMoreUrl     = $LearnMoreUrl
        EntityId         = $EntityId
        EntityType       = $EntityType
        Platform         = $resolvedPlatform
        Provenance       = $provenance
        SubscriptionId   = $SubscriptionId
        SubscriptionName = $SubscriptionName
        ResourceGroup    = $ResourceGroup
        ManagementGroupPath = $ManagementGroupPath
        Frameworks       = $Frameworks
        Controls         = $Controls
        Confidence       = $Confidence
        EvidenceCount    = $EvidenceCount
        MissingDimensions = $MissingDimensions
        Pillar           = $Pillar
        Impact           = $Impact
        Effort           = $Effort
        DeepLinkUrl      = $DeepLinkUrl
        RemediationSnippets = $RemediationSnippets
        EvidenceUris     = $EvidenceUris
        BaselineTags     = $BaselineTags
        ScoreDelta       = $ScoreDelta
        MitreTactics     = $MitreTactics
        MitreTechniques  = $MitreTechniques
        EntityRefs       = $EntityRefs
        ToolVersion      = $ToolVersion
        SchemaVersion    = $SchemaVersion
    }

    # Validate the row before returning it
    $validationErrors = @()
    $isValid = Test-FindingRow -Finding $row -ErrorDetails ([ref]$validationErrors)
    if (-not $isValid) {
        # Sanitize error message
        $sanitizedError = if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
            Remove-Credentials ($validationErrors -join '; ')
        } else {
            $validationErrors -join '; '
        }

        # Log the failure
        $script:ValidationFailures.Add([PSCustomObject]@{
            Source    = $Source
            Error     = $sanitizedError
            Timestamp = Get-Date
        })

        # Write warning to stderr
        Write-Warning "FindingRow validation failed [$Source]: $sanitizedError"
        
        # Return null to signal failure (caller should skip this row)
        return $null
    }

    return $row
}

function New-EntityStub {
    <#
    .SYNOPSIS
        Create an entity stub with canonical identity and empty observations.
    .DESCRIPTION
        CanonicalId is mapped to the EntityId field. Observations are initialized
        as an empty array by default.
    .PARAMETER CanonicalId
        Canonical entity identifier.
    .PARAMETER EntityType
        Entity type enum.
    .PARAMETER Platform
        Entity platform.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CanonicalId,

        [Parameter(Mandatory)]
        [ValidateSet(
            'AzureResource',
            'ServicePrincipal',
            'ManagedIdentity',
            'Application',
            'Repository',
            'IaCFile',
            'BuildDefinition',
            'ReleaseDefinition',
            'Pipeline',
            'ServiceConnection',
            'User',
            'Subscription',
            'ManagementGroup',
            'Workflow',
            'Tenant',
            'AdoProject',
            'KarpenterProvisioner'
        )]
        [string] $EntityType,

        [ValidateSet('Azure', 'Entra', 'GitHub', 'ADO', 'AzureDevOps', 'IaC')]
        [string] $Platform,

        [string] $DisplayName,
        [string] $SubscriptionId,
        [string] $SubscriptionName,
        [string] $ResourceGroup,
        [string[]] $ManagementGroupPath,
        [object[]] $ExternalIds,
        [object[]] $Frameworks,
        [string[]] $Controls,
        [object[]] $Policies,
        [object[]] $Correlations,
        [double] $MonthlyCost,
        [string] $Currency,
        [string] $CostTrend,
        [ValidateSet('Confirmed', 'Likely', 'Unconfirmed', 'Unknown')]
        [string] $Confidence,
        [string[]] $MissingDimensions,
        [object[]] $Observations
    )

    $resolvedPlatform = if ($Platform) { $Platform } else { Get-PlatformForEntityType -EntityType $EntityType }
    $initialObservations = if ($Observations) { @($Observations) } else { @() }

    [PSCustomObject]@{
        EntityId         = $CanonicalId
        EntityType       = $EntityType
        Platform         = $resolvedPlatform
        DisplayName      = $DisplayName
        SubscriptionId   = $SubscriptionId
        SubscriptionName = $SubscriptionName
        ResourceGroup    = $ResourceGroup
        ManagementGroupPath = $ManagementGroupPath
        ExternalIds      = $ExternalIds
        Observations     = $initialObservations
        WorstSeverity    = $null
        CompliantCount   = 0
        NonCompliantCount = 0
        Sources          = @()
        MonthlyCost      = $MonthlyCost
        Currency         = $Currency
        CostTrend        = $CostTrend
        Frameworks       = $Frameworks
        Controls         = $Controls
        Policies         = $Policies
        Correlations     = $Correlations
        Confidence       = $Confidence
        MissingDimensions = $MissingDimensions
    }
}

function Test-FindingRow {
    <#
    .SYNOPSIS
        Validate a finding row against schema v2/v3 requirements.
    .DESCRIPTION
        By default returns $true/$false with errors via -ErrorDetails.
        Use -Strict to throw a FindingRowSchemaException instead.
    .PARAMETER Finding
        Finding row to validate.
    .PARAMETER ErrorDetails
        Output array of validation errors (populated when -Strict is not used).
    .PARAMETER Strict
        When set, throws a FindingRowSchemaException with all validation errors
        instead of returning false.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $Finding,

        [ref] $ErrorDetails,

        [switch] $Strict
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # Required fields
    foreach ($required in @('Id', 'Source', 'EntityId', 'EntityType', 'Title', 'SchemaVersion')) {
        if (-not $Finding.PSObject.Properties[$required]) {
            $errors.Add("Required field '$required' is missing.")
        } elseif ([string]::IsNullOrWhiteSpace([string]$Finding.$required)) {
            $errors.Add("Required field '$required' is empty.")
        }
    }

    # Compliant must be present and boolean
    if (-not $Finding.PSObject.Properties['Compliant']) {
        $errors.Add("Required field 'Compliant' is missing.")
    } elseif ($null -eq $Finding.Compliant) {
        $errors.Add("Compliant must be a boolean value, got 'null'.")
    } elseif ($Finding.Compliant -isnot [bool]) {
        $errors.Add("Compliant must be a boolean value, got '$($Finding.Compliant.GetType().Name)'.")
    }

    # EntityType validation
    if ($Finding.PSObject.Properties['EntityType'] -and $Finding.EntityType) {
        if ($Finding.EntityType -notin $script:EntityTypes) {
            $errors.Add("EntityType '$($Finding.EntityType)' is not valid. Valid types: $($script:EntityTypes -join ', ').")
        }
    }

    # Platform validation
    if ($Finding.PSObject.Properties['Platform'] -and $Finding.Platform) {
        if ($Finding.Platform -notin $script:Platforms) {
            $errors.Add("Platform '$($Finding.Platform)' is not valid. Valid platforms: $($script:Platforms -join ', ').")
        }
    }

    # Severity validation
    if ($Finding.PSObject.Properties['Severity'] -and $Finding.Severity) {
        if ($Finding.Severity -notin $script:SeverityLevels) {
            $errors.Add("Severity '$($Finding.Severity)' is not valid. Valid levels: $($script:SeverityLevels -join ', ').")
        }
    }

    # Provenance.RunId validation
    if (-not $Finding.PSObject.Properties['Provenance']) {
        $errors.Add("Provenance is missing.")
    } elseif (-not $Finding.Provenance) {
        $errors.Add("Provenance is null.")
    } elseif (-not $Finding.Provenance.PSObject.Properties['RunId']) {
        $errors.Add("Provenance.RunId is missing.")
    } elseif ([string]::IsNullOrWhiteSpace($Finding.Provenance.RunId)) {
        $errors.Add("Provenance.RunId is empty.")
    }

    # EntityId canonicalization check (when possible)
    if ($Finding.PSObject.Properties['EntityId'] -and $Finding.EntityId -and 
        $Finding.PSObject.Properties['EntityType'] -and $Finding.EntityType -and
        (-not ($Finding.PSObject.Properties['Platform'] -and $Finding.Platform -eq 'AzureDevOps')) -and
        (Get-Command ConvertTo-CanonicalEntityId -ErrorAction SilentlyContinue)) {
        try {
            $result = ConvertTo-CanonicalEntityId -RawId $Finding.EntityId -EntityType $Finding.EntityType
            $canonicalId = $result.CanonicalId
            # Use case-sensitive comparison (-cne)
            if ($canonicalId -cne $Finding.EntityId) {
                $errors.Add("EntityId canonicalization check failed: expected '$canonicalId', got '$($Finding.EntityId)'.")
            }
        } catch {
            # Canonicalization failed, record the error
            $errors.Add("EntityId canonicalization check failed: $_")
        }
    }

    # Return or throw
    $isValid = $errors.Count -eq 0

    if (-not $isValid -and $Strict) {
        $aggregatedError = "FindingRow schema validation failed with $($errors.Count) error(s):`n" + ($errors -join "`n")
        throw [System.Exception]::new($aggregatedError)
    }

    if ($ErrorDetails) {
        $ErrorDetails.Value = $errors.ToArray()
    }

    return $isValid
}

function Get-EdgeRelations {
    <#
    .SYNOPSIS
        Returns the allowed Edge.Relation values.
    #>
    [CmdletBinding()]
    param ()
    return ,$script:EdgeRelations
}

function New-Edge {
    <#
    .SYNOPSIS
        Construct a v3.1 Edge object representing a relationship between two entities.
    .DESCRIPTION
        Edges are first-class records persisted alongside entities. The EdgeId is
        deterministic ("edge:{source}:{relation}:{target}" lower-cased) so that
        repeated discovery rounds dedup naturally. Returns $null with a warning
        when validation fails (mirrors New-FindingRow contract).
    .PARAMETER Source
        Canonical entity id of the source vertex.
    .PARAMETER Target
        Canonical entity id of the target vertex.
    .PARAMETER Relation
        One of the Edge.Relation enum values (see Get-EdgeRelations).
    .PARAMETER Properties
        Hashtable / PSCustomObject of relation-specific metadata (e.g. role name,
        scope, consent type). Optional.
    .PARAMETER Confidence
        Confirmed | Likely | Unconfirmed | Unknown.
    .PARAMETER Platform
        Platform that owns this edge fact (Azure | Entra | GitHub | ADO).
    .PARAMETER DiscoveredBy
        Wrapper / tool that produced the edge.
    .PARAMETER DiscoveredAt
        ISO-8601 timestamp; defaults to UtcNow.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Source,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Target,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Relation,

        [object] $Properties,

        [string] $Confidence = 'Unknown',

        [string] $Platform,

        [string] $DiscoveredBy,

        [datetime] $DiscoveredAt
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Source)) { $errors.Add("Required parameter 'Source' is missing or empty.") }
    if ([string]::IsNullOrWhiteSpace($Target)) { $errors.Add("Required parameter 'Target' is missing or empty.") }
    if ([string]::IsNullOrWhiteSpace($Relation)) {
        $errors.Add("Required parameter 'Relation' is missing or empty.")
    } elseif ($Relation -notin $script:EdgeRelations) {
        $errors.Add("Relation '$Relation' is not valid. Valid relations: $($script:EdgeRelations -join ', ').")
    }
    if ($Confidence -and $Confidence -notin $script:ConfidenceLevels) {
        $errors.Add("Confidence '$Confidence' is not valid. Valid confidence levels: $($script:ConfidenceLevels -join ', ').")
    }
    if ($Platform -and $Platform -notin $script:Platforms) {
        $errors.Add("Platform '$Platform' is not valid. Valid platforms: $($script:Platforms -join ', ').")
    }

    if ($errors.Count -gt 0) {
        $sourceForLog = if ([string]::IsNullOrWhiteSpace($DiscoveredBy)) { 'unknown' } else { $DiscoveredBy }
        $sanitizedError = if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
            Remove-Credentials ($errors -join '; ')
        } else {
            $errors -join '; '
        }
        $script:ValidationFailures.Add([PSCustomObject]@{
                Source    = $sourceForLog
                Error     = "Edge validation failed: $sanitizedError"
                Timestamp = Get-Date
            })
        Write-Warning "Edge validation failed [$sourceForLog]: $sanitizedError"
        return $null
    }

    $srcLower = $Source.Trim().ToLowerInvariant()
    $tgtLower = $Target.Trim().ToLowerInvariant()
    $edgeId = "edge:$srcLower|$Relation|$tgtLower"

    $propBag = if ($null -eq $Properties) {
        [PSCustomObject]@{}
    } elseif ($Properties -is [System.Collections.IDictionary]) {
        [PSCustomObject]$Properties
    } else {
        $Properties
    }

    $stamp = if ($PSBoundParameters.ContainsKey('DiscoveredAt') -and $DiscoveredAt) {
        $DiscoveredAt.ToUniversalTime().ToString('o')
    } else {
        (Get-Date).ToUniversalTime().ToString('o')
    }

    [PSCustomObject]@{
        EdgeId        = $edgeId
        Source        = $srcLower
        Target        = $tgtLower
        Relation      = $Relation
        Properties    = $propBag
        Confidence    = $Confidence
        Platform      = $Platform
        DiscoveredBy  = $DiscoveredBy
        DiscoveredAt  = $stamp
        SchemaVersion = $script:EntitiesFileSchemaVersion
    }
}

function Test-Edge {
    <#
    .SYNOPSIS
        Validate an edge object against the v3.1 contract.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $Edge,

        [ref] $ErrorDetails
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($required in @('EdgeId', 'Source', 'Target', 'Relation')) {
        if (-not $Edge.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$Edge.$required)) {
            $errors.Add("Required field '$required' is missing or empty.")
        }
    }
    if ($Edge.PSObject.Properties['Relation'] -and $Edge.Relation -and $Edge.Relation -notin $script:EdgeRelations) {
        $errors.Add("Relation '$($Edge.Relation)' is not in allowed set: $($script:EdgeRelations -join ', ').")
    }
    if ($Edge.PSObject.Properties['Confidence'] -and $Edge.Confidence -and $Edge.Confidence -notin $script:ConfidenceLevels) {
        $errors.Add("Confidence '$($Edge.Confidence)' is not in allowed set: $($script:ConfidenceLevels -join ', ').")
    }
    if ($Edge.PSObject.Properties['Platform'] -and $Edge.Platform -and $Edge.Platform -notin $script:Platforms) {
        $errors.Add("Platform '$($Edge.Platform)' is not in allowed set: $($script:Platforms -join ', ').")
    }
    if ($ErrorDetails) { $ErrorDetails.Value = $errors.ToArray() }
    return $errors.Count -eq 0
}

function Test-EntityRecord {
    <#
    .SYNOPSIS
        Validate an entity record.
    .DESCRIPTION
        Returns $true when valid. When invalid, returns $false and provides
        error details via -ErrorDetails.
    .PARAMETER Entity
        Entity record to validate.
    .PARAMETER ErrorDetails
        Output array of validation errors.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $Entity,

        [ref] $ErrorDetails
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($required in @('EntityId', 'EntityType', 'Platform')) {
        if (-not $Entity.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$Entity.$required)) {
            $errors.Add("Required field '$required' is missing or empty.")
        }
    }

    if ($Entity.EntityType -and $Entity.EntityType -notin $script:EntityTypes) {
        $errors.Add("EntityType '$($Entity.EntityType)' is not in the allowed set: $($script:EntityTypes -join ', ').")
    }

    if ($Entity.Platform -and $Entity.Platform -notin $script:Platforms) {
        $errors.Add("Platform '$($Entity.Platform)' is not in the allowed set: $($script:Platforms -join ', ').")
    }

    if ($Entity.Observations -and $Entity.Observations -isnot [System.Collections.IEnumerable]) {
        $errors.Add("Observations must be an array.")
    }

    $canonicalizer = Get-Command -Name ConvertTo-CanonicalEntityId -ErrorAction SilentlyContinue
    if ($canonicalizer -and $Entity.EntityId -and $Entity.EntityType -and $Entity.Platform -ne 'AzureDevOps') {
        try {
            $canonical = ConvertTo-CanonicalEntityId -RawId $Entity.EntityId -EntityType $Entity.EntityType
            if ($canonical.CanonicalId -cne $Entity.EntityId) {
                $errors.Add("EntityId is not canonicalized. Expected '$($canonical.CanonicalId)'.")
            }
        } catch {
            $errors.Add("EntityId canonicalization failed: $_")
        }
    }

    if ($ErrorDetails) {
        $ErrorDetails.Value = $errors.ToArray()
    }

    return $errors.Count -eq 0
}
