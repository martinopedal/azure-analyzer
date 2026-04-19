#Requires -Version 7.4
<#
.SYNOPSIS
    Send findings and entities to Azure Monitor Logs Ingestion API.
.DESCRIPTION
    Reads entities.json output from azure-analyzer, derives finding rows from
    entity observations, and sends findings/entities to configured DCR streams.
    Uses Invoke-WithRetry for transient failures and enforces HTTPS endpoints.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = Join-Path $PSScriptRoot '..' 'shared'
foreach ($sharedModule in @('Sanitize', 'Retry')) {
    $sharedPath = Join-Path $sharedDir "$sharedModule.ps1"
    if (Test-Path $sharedPath) { . $sharedPath }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock) & $ScriptBlock }
}

$script:MaxIngestionBodyBytes = 1MB
$script:MaxIngestionRecordsPerBatch = 1500

function Test-LogAnalyticsEndpoint {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $DceEndpoint
    )

    if ($DceEndpoint -notmatch '^https://') {
        throw "DceEndpoint must use HTTPS. Received: $DceEndpoint"
    }

    try {
        $uri = [System.Uri]$DceEndpoint
    } catch {
        throw "DceEndpoint is not a valid URI: $DceEndpoint"
    }

    if ($uri.Scheme -ne 'https') {
        throw "DceEndpoint must use HTTPS. Received scheme: $($uri.Scheme)"
    }
}

function Read-EntitiesFromJson {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $EntitiesJson
    )

    if (-not (Test-Path $EntitiesJson)) {
        throw "EntitiesJson file not found: $EntitiesJson"
    }

    try {
        return @(Get-Content -Path $EntitiesJson -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        $msg = Remove-Credentials "$_"
        throw "Failed to parse entities JSON: $msg"
    }
}

function Get-LogAnalyticsAccessToken {
    [CmdletBinding()]
    param ()

    try {
        $token = Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com/' -ErrorAction Stop
    } catch {
        $msg = Remove-Credentials "$_"
        throw "Failed to acquire Azure Monitor token via Get-AzAccessToken: $msg"
    }

    $resolvedToken = if ($token.PSObject.Properties['Token']) { [string]$token.Token } else { '' }
    if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
        throw "Get-AzAccessToken returned an empty token."
    }

    return $resolvedToken
}

function Convert-ToLogAnalyticsScalar {
    [CmdletBinding()]
    param (
        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o')
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ($Value | ConvertTo-Json -Depth 30 -Compress)
    }
    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Convert-FindingToLogAnalyticsRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Finding
    )

    $runId = if ($Finding.PSObject.Properties['Provenance'] -and $Finding.Provenance -and $Finding.Provenance.PSObject.Properties['RunId']) {
        [string]$Finding.Provenance.RunId
    } else {
        ''
    }
    $provenanceSource = if ($Finding.PSObject.Properties['Provenance'] -and $Finding.Provenance -and $Finding.Provenance.PSObject.Properties['Source']) {
        [string]$Finding.Provenance.Source
    } else {
        ''
    }
    $provenanceTimestamp = if ($Finding.PSObject.Properties['Provenance'] -and $Finding.Provenance -and $Finding.Provenance.PSObject.Properties['Timestamp']) {
        [string]$Finding.Provenance.Timestamp
    } else {
        ''
    }
    $provenanceRawRecordRef = if ($Finding.PSObject.Properties['Provenance'] -and $Finding.Provenance -and $Finding.Provenance.PSObject.Properties['RawRecordRef']) {
        [string]$Finding.Provenance.RawRecordRef
    } else {
        ''
    }

    [PSCustomObject]@{
        TimeGenerated          = if ($provenanceTimestamp) { $provenanceTimestamp } else { (Get-Date).ToUniversalTime().ToString('o') }
        RunId                  = $runId
        FindingId              = [string]$Finding.Id
        Source                 = [string]$Finding.Source
        Category               = [string]$Finding.Category
        Title                  = [string]$Finding.Title
        Severity               = [string]$Finding.Severity
        Compliant              = [bool]$Finding.Compliant
        Detail                 = [string]$Finding.Detail
        Remediation            = [string]$Finding.Remediation
        ResourceId             = [string]$Finding.ResourceId
        LearnMoreUrl           = [string]$Finding.LearnMoreUrl
        EntityId               = [string]$Finding.EntityId
        EntityType             = [string]$Finding.EntityType
        Platform               = [string]$Finding.Platform
        SubscriptionId         = [string]$Finding.SubscriptionId
        SubscriptionName       = [string]$Finding.SubscriptionName
        ResourceGroup          = [string]$Finding.ResourceGroup
        ManagementGroupPath    = Convert-ToLogAnalyticsScalar -Value $Finding.ManagementGroupPath
        Frameworks             = Convert-ToLogAnalyticsScalar -Value $Finding.Frameworks
        Controls               = Convert-ToLogAnalyticsScalar -Value $Finding.Controls
        Confidence             = [string]$Finding.Confidence
        EvidenceCount          = if ($Finding.PSObject.Properties['EvidenceCount']) { [int]$Finding.EvidenceCount } else { 0 }
        MissingDimensions      = Convert-ToLogAnalyticsScalar -Value $Finding.MissingDimensions
        SchemaVersion          = [string]$Finding.SchemaVersion
        ProvenanceSource       = $provenanceSource
        ProvenanceTimestamp    = $provenanceTimestamp
        ProvenanceRawRecordRef = $provenanceRawRecordRef
    }
}

function Convert-EntityToLogAnalyticsRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Entity
    )

    $observations = @($Entity.Observations)
    $runIds = @($observations | ForEach-Object {
            if ($_.PSObject.Properties['Provenance'] -and $_.Provenance -and $_.Provenance.PSObject.Properties['RunId']) {
                [string]$_.Provenance.RunId
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    [PSCustomObject]@{
        TimeGenerated       = (Get-Date).ToUniversalTime().ToString('o')
        RunId               = ($runIds -join ',')
        FindingId           = ''
        EntityId            = [string]$Entity.EntityId
        EntityType          = [string]$Entity.EntityType
        Platform            = [string]$Entity.Platform
        DisplayName         = [string]$Entity.DisplayName
        SubscriptionId      = [string]$Entity.SubscriptionId
        SubscriptionName    = [string]$Entity.SubscriptionName
        ResourceGroup       = [string]$Entity.ResourceGroup
        ManagementGroupPath = Convert-ToLogAnalyticsScalar -Value $(if ($Entity.PSObject.Properties['ManagementGroupPath']) { $Entity.ManagementGroupPath } else { @() })
        WorstSeverity       = if ($Entity.PSObject.Properties['WorstSeverity']) { [string]$Entity.WorstSeverity } else { '' }
        CompliantCount      = if ($Entity.PSObject.Properties['CompliantCount']) { [int]$Entity.CompliantCount } else { 0 }
        NonCompliantCount   = if ($Entity.PSObject.Properties['NonCompliantCount']) { [int]$Entity.NonCompliantCount } else { 0 }
        ObservationCount    = $observations.Count
        Sources             = Convert-ToLogAnalyticsScalar -Value $(if ($Entity.PSObject.Properties['Sources']) { $Entity.Sources } else { @() })
        Frameworks          = Convert-ToLogAnalyticsScalar -Value $(if ($Entity.PSObject.Properties['Frameworks']) { $Entity.Frameworks } else { @() })
        Controls            = Convert-ToLogAnalyticsScalar -Value $(if ($Entity.PSObject.Properties['Controls']) { $Entity.Controls } else { @() })
        Confidence          = if ($Entity.PSObject.Properties['Confidence']) { [string]$Entity.Confidence } else { '' }
        MissingDimensions   = Convert-ToLogAnalyticsScalar -Value $(if ($Entity.PSObject.Properties['MissingDimensions']) { $Entity.MissingDimensions } else { @() })
        EntityRecord        = Convert-ToLogAnalyticsScalar -Value $Entity
    }
}

function New-LogAnalyticsBatches {
    [CmdletBinding()]
    param (
        [object[]] $Records = @()
    )

    if (-not $Records -or $Records.Count -eq 0) { return @() }

    $batches = [System.Collections.Generic.List[object[]]]::new()
    $currentBatch = [System.Collections.Generic.List[object]]::new()
    $currentBytes = 2 # []

    foreach ($record in $Records) {
        $recordJson = $record | ConvertTo-Json -Depth 30 -Compress
        $recordBytes = [System.Text.Encoding]::UTF8.GetByteCount($recordJson)
        if ($recordBytes -gt $script:MaxIngestionBodyBytes) {
            throw "A single record exceeds the $($script:MaxIngestionBodyBytes) byte Logs Ingestion limit."
        }

        $commaBytes = if ($currentBatch.Count -gt 0) { 1 } else { 0 }
        $wouldBeBytes = $currentBytes + $recordBytes + $commaBytes
        $wouldBeCount = $currentBatch.Count + 1
        $overLimit = ($wouldBeCount -gt $script:MaxIngestionRecordsPerBatch) -or ($wouldBeBytes -gt $script:MaxIngestionBodyBytes)

        if ($overLimit -and $currentBatch.Count -gt 0) {
            $batches.Add($currentBatch.ToArray())
            $currentBatch = [System.Collections.Generic.List[object]]::new()
            $currentBytes = 2
            $commaBytes = 0
            $wouldBeBytes = $currentBytes + $recordBytes
        }

        $currentBatch.Add($record)
        $currentBytes = $wouldBeBytes
    }

    if ($currentBatch.Count -gt 0) {
        $batches.Add($currentBatch.ToArray())
    }

    return $batches.ToArray()
}

function Invoke-LogAnalyticsIngestion {
    [CmdletBinding()]
    param (
        [object[]] $Records = @(),

        [Parameter(Mandatory)]
        [string] $DceEndpoint,

        [Parameter(Mandatory)]
        [string] $DcrImmutableId,

        [Parameter(Mandatory)]
        [string] $StreamName,

        [switch] $DryRun,

        [string] $DryRunOutputPath
    )

    if ([string]::IsNullOrWhiteSpace($DceEndpoint)) { throw "DceEndpoint is required." }
    if ([string]::IsNullOrWhiteSpace($DcrImmutableId)) { throw "DcrImmutableId is required." }
    if ([string]::IsNullOrWhiteSpace($StreamName)) { throw "StreamName is required." }

    Test-LogAnalyticsEndpoint -DceEndpoint $DceEndpoint
    $endpoint = $DceEndpoint.TrimEnd('/')
    $uri = "$endpoint/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=2023-01-01"

    $batches = @(New-LogAnalyticsBatches -Records $Records)
    if ($batches.Count -eq 0) {
        return [PSCustomObject]@{
            RecordsProcessed = 0
            BatchesProcessed = 0
            Uri              = $uri
            DryRun           = [bool]$DryRun
        }
    }

    $token = $null
    if (-not $DryRun) {
        $token = Get-LogAnalyticsAccessToken
    }

    $dryRunRows = [System.Collections.Generic.List[object]]::new()
    $batchIndex = 0
    foreach ($batch in $batches) {
        $batchIndex++
        $body = $batch | ConvertTo-Json -Depth 30 -Compress
        $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($body)

        if ($DryRun) {
            $dryRunRows.Add([PSCustomObject]@{
                    BatchIndex  = $batchIndex
                    Uri         = $uri
                    StreamName  = $StreamName
                    RecordCount = @($batch).Count
                    BodyBytes   = $bodyBytes
                    Body        = $body
                }) | Out-Null
            continue
        }

        $headers = @{
            Authorization          = "Bearer $token"
            'x-ms-client-request-id' = [guid]::NewGuid().ToString()
        }

        Invoke-WithRetry -ScriptBlock {
            Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 300 -ErrorAction Stop | Out-Null
        } | Out-Null
    }

    if ($DryRun -and $DryRunOutputPath) {
        $dryRunJson = $dryRunRows.ToArray() | ConvertTo-Json -Depth 40
        $dryRunJson = Remove-Credentials $dryRunJson
        Set-Content -Path $DryRunOutputPath -Value $dryRunJson -Encoding UTF8
    }

    return [PSCustomObject]@{
        RecordsProcessed = @($Records).Count
        BatchesProcessed = $batches.Count
        Uri              = $uri
        DryRun           = [bool]$DryRun
        DryRunOutputPath = if ($DryRun) { $DryRunOutputPath } else { '' }
    }
}

function Send-FindingsToLogAnalytics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $EntitiesJson,

        [Parameter(Mandatory)]
        [string] $DceEndpoint,

        [Parameter(Mandatory)]
        [string] $DcrImmutableId,

        [Parameter(Mandatory)]
        [string] $StreamName,

        [switch] $DryRun
    )

    $entities = @(Read-EntitiesFromJson -EntitiesJson $EntitiesJson)
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($entity in $entities) {
        foreach ($obs in @($entity.Observations)) {
            if ($obs) { $findings.Add($obs) | Out-Null }
        }
    }

    $records = @($findings.ToArray() | ForEach-Object { Convert-FindingToLogAnalyticsRecord -Finding $_ })
    $dryRunOutputPath = Join-Path (Split-Path -Parent $EntitiesJson) 'log-analytics-findings-dryrun.json'
    return Invoke-LogAnalyticsIngestion -Records $records -DceEndpoint $DceEndpoint -DcrImmutableId $DcrImmutableId -StreamName $StreamName -DryRun:$DryRun -DryRunOutputPath $dryRunOutputPath
}

function Send-EntitiesToLogAnalytics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $EntitiesJson,

        [Parameter(Mandatory)]
        [string] $DceEndpoint,

        [Parameter(Mandatory)]
        [string] $DcrImmutableId,

        [Parameter(Mandatory)]
        [string] $StreamName,

        [switch] $DryRun
    )

    $entities = @(Read-EntitiesFromJson -EntitiesJson $EntitiesJson)
    $records = @($entities | ForEach-Object { Convert-EntityToLogAnalyticsRecord -Entity $_ })
    $dryRunOutputPath = Join-Path (Split-Path -Parent $EntitiesJson) 'log-analytics-entities-dryrun.json'
    return Invoke-LogAnalyticsIngestion -Records $records -DceEndpoint $DceEndpoint -DcrImmutableId $DcrImmutableId -StreamName $StreamName -DryRun:$DryRun -DryRunOutputPath $dryRunOutputPath
}
