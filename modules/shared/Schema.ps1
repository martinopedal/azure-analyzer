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

$script:SchemaVersion = '2.0'
$script:SeverityLevels = @('Critical', 'High', 'Medium', 'Low', 'Info')
$script:EntityTypes = @(
    'AzureResource',
    'ServicePrincipal',
    'ManagedIdentity',
    'Application',
    'Repository',
    'Pipeline',
    'ServiceConnection',
    'User',
    'Subscription',
    'ManagementGroup',
    'Workflow',
    'Tenant'
)
$script:Platforms = @('Azure', 'Entra', 'GitHub', 'ADO')
$script:ConfidenceLevels = @('Confirmed', 'Likely', 'Unconfirmed', 'Unknown')
$script:ValidationFailures = [System.Collections.Generic.List[PSCustomObject]]::new()

function Get-PlatformForEntityType {
    param (
        [Parameter(Mandatory)]
        [ValidateSet(
            'AzureResource',
            'ServicePrincipal',
            'ManagedIdentity',
            'Application',
            'Repository',
            'Pipeline',
            'ServiceConnection',
            'User',
            'Subscription',
            'ManagementGroup',
            'Workflow',
            'Tenant'
        )]
        [string] $EntityType
    )

    switch ($EntityType) {
        'AzureResource' { 'Azure' }
        'ManagedIdentity' { 'Azure' }
        'Subscription' { 'Azure' }
        'ManagementGroup' { 'Azure' }
        'ServicePrincipal' { 'Entra' }
        'Application' { 'Entra' }
        'User' { 'Entra' }
        'Tenant' { 'Entra' }
        'Repository' { 'GitHub' }
        'Workflow' { 'GitHub' }
        'Pipeline' { 'ADO' }
        'ServiceConnection' { 'ADO' }
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
    .PARAMETER Compliant
        Boolean compliance status.
    .PARAMETER ProvenanceRunId
        Run identifier for the tool execution.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Source,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EntityId,

        [Parameter(Mandatory)]
        [ValidateSet(
            'AzureResource',
            'ServicePrincipal',
            'ManagedIdentity',
            'Application',
            'Repository',
            'Pipeline',
            'ServiceConnection',
            'User',
            'Subscription',
            'ManagementGroup',
            'Workflow',
            'Tenant'
        )]
        [string] $EntityType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [bool] $Compliant,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ProvenanceRunId,

        [string] $Category,
        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')]
        [string] $Severity,
        [string] $Detail,
        [string] $Remediation,
        [string] $ResourceId,
        [string] $LearnMoreUrl,
        [ValidateSet('Azure', 'Entra', 'GitHub', 'ADO')]
        [string] $Platform,
        [string] $SubscriptionId,
        [string] $SubscriptionName,
        [string] $ResourceGroup,
        [string[]] $ManagementGroupPath,
        [object[]] $Frameworks,
        [string[]] $Controls,
        [ValidateSet('Confirmed', 'Likely', 'Unconfirmed', 'Unknown')]
        [string] $Confidence,
        [int] $EvidenceCount,
        [string[]] $MissingDimensions,
        [string] $ProvenanceSource,
        [string] $ProvenanceRawRecordRef,
        [datetime] $ProvenanceTimestamp,
        [string] $SchemaVersion = $script:SchemaVersion
    )

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
        Severity         = $Severity
        Compliant        = $Compliant
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
            'Pipeline',
            'ServiceConnection',
            'User',
            'Subscription',
            'ManagementGroup',
            'Workflow',
            'Tenant'
        )]
        [string] $EntityType,

        [ValidateSet('Azure', 'Entra', 'GitHub', 'ADO')]
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
    if ($canonicalizer -and $Entity.EntityId -and $Entity.EntityType) {
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
