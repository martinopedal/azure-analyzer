#Requires -Version 7.4
<#
.SYNOPSIS
    Wrapper for Microsoft Defender for Cloud subscription data.
.DESCRIPTION
    Collects subscription secure score and active assessments via Microsoft.Security
    REST endpoints. Returns wrapper output compatible with normalizers.
    Gracefully skips when Defender for Cloud is not enabled on the subscription
    (HTTP 404/409 from secureScores endpoint).
.PARAMETER SubscriptionId
    Azure subscription ID to query.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ErrorStatusCode {
    param ([object] $ErrorRecord)

    if ($null -eq $ErrorRecord) { return $null }

    $exception = $ErrorRecord.Exception
    $response = if ($exception -and $exception.PSObject.Properties['Response']) { $exception.Response } else { $null }
    $responseStatusCode = if ($response -and $response.PSObject.Properties['StatusCode']) { $response.StatusCode } else { $null }
    $exceptionStatusCode = if ($exception -and $exception.PSObject.Properties['StatusCode']) { $exception.StatusCode } else { $null }

    $candidates = @(
        $(if ($responseStatusCode -and $responseStatusCode.PSObject.Properties['value__']) { $responseStatusCode.value__ } else { $null }),
        $responseStatusCode,
        $(if ($exceptionStatusCode -and $exceptionStatusCode.PSObject.Properties['value__']) { $exceptionStatusCode.value__ } else { $null }),
        $exceptionStatusCode
    )
    foreach ($candidate in $candidates) {
        if ($candidate -is [int]) { return [int]$candidate }
        $parsed = 0
        if ($candidate -and [int]::TryParse([string]$candidate, [ref]$parsed)) { return $parsed }
    }

    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match '\((?<code>\d{3})\)') { return [int]$Matches['code'] }
    if ($message -match '\b(?<code>404|409)\b') { return [int]$Matches['code'] }
    return $null
}

function ConvertFrom-AzRestContent {
    param ([object] $Response)
    if ($null -eq $Response) { return $null }
    $content = $Response.Content
    if ([string]::IsNullOrWhiteSpace([string]$content)) { return $null }
    return ($content | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
}

function ConvertTo-RestPath {
    param ([string] $NextLink)
    if ([string]::IsNullOrWhiteSpace($NextLink)) { return $null }
    if ($NextLink.StartsWith('/')) { return $NextLink }
    try {
        $uri = [uri]$NextLink
        return "$($uri.AbsolutePath)$($uri.Query)"
    } catch {
        return $NextLink
    }
}

if (-not (Get-Module -Name Az.Security -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Warning "Az.Security module not installed. Skipping Defender for Cloud scan. Run: Install-Module Az.Security -Scope CurrentUser"
    return [PSCustomObject]@{
        Source         = 'defender-for-cloud'
        Status         = 'Skipped'
        Message        = 'Az.Security module not installed'
        SubscriptionId = $SubscriptionId
        Findings       = @()
    }
}

if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
    Write-Warning "Invoke-AzRestMethod is unavailable. Install Az.Accounts and reconnect."
    return [PSCustomObject]@{
        Source         = 'defender-for-cloud'
        Status         = 'Skipped'
        Message        = 'Invoke-AzRestMethod not available'
        SubscriptionId = $SubscriptionId
        Findings       = @()
    }
}

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $secureScorePath = "/subscriptions/$SubscriptionId/providers/Microsoft.Security/secureScores?api-version=2020-01-01-preview"
    $secureScoreResponse = Invoke-AzRestMethod -Method GET -Path $secureScorePath -ErrorAction Stop
    $secureScorePayload = ConvertFrom-AzRestContent -Response $secureScoreResponse
} catch {
    $statusCode = Get-ErrorStatusCode -ErrorRecord $_
    if ($statusCode -in @(404, 409)) {
        return [PSCustomObject]@{
            Source         = 'defender-for-cloud'
            Status         = 'Skipped'
            Message        = "Defender for Cloud is not enabled for subscription $SubscriptionId"
            SubscriptionId = $SubscriptionId
            Findings       = @()
        }
    }
    Write-Warning "Defender secureScores query failed: $_"
    return [PSCustomObject]@{
        Source         = 'defender-for-cloud'
        Status         = 'Failed'
        Message        = "$_"
        SubscriptionId = $SubscriptionId
        Findings       = @()
    }
}

$secureScoreRow = @($secureScorePayload.value)[0]
if ($secureScoreRow) {
    $scoreCurrent = [double]($secureScoreRow.properties.score.current ?? 0)
    $scoreMax = [double]($secureScoreRow.properties.score.max ?? 0)
    $scorePct = if ($scoreMax -gt 0) { [Math]::Round(($scoreCurrent / $scoreMax) * 100, 2) } else { 0 }
    $findings.Add([PSCustomObject]@{
        RecordType     = 'SecureScore'
        SubscriptionId = $SubscriptionId
        Title          = 'Defender for Cloud Secure Score'
        Current        = $scoreCurrent
        Max            = $scoreMax
        Percentage     = $scorePct
    })
}

try {
    $nextPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Security/assessments?api-version=2021-06-01"
    while ($nextPath) {
        $assessmentResponse = Invoke-AzRestMethod -Method GET -Path $nextPath -ErrorAction Stop
        $assessmentPayload = ConvertFrom-AzRestContent -Response $assessmentResponse
        foreach ($assessment in @($assessmentPayload.value)) {
            if (-not $assessment) { continue }
            $resourceId = $assessment.properties.resourceDetails.id ?? ''
            $findings.Add([PSCustomObject]@{
                RecordType     = 'Assessment'
                SubscriptionId = $SubscriptionId
                AssessmentId   = ($assessment.name ?? $assessment.id ?? '')
                StatusCode     = ($assessment.properties.status.code ?? '')
                Title          = ($assessment.properties.displayName ?? 'Defender recommendation')
                Severity       = ($assessment.properties.metadata.severity ?? 'Medium')
                Description    = ($assessment.properties.metadata.description ?? '')
                Remediation    = ($assessment.properties.metadata.remediationDescription ?? '')
                ResourceId     = [string]$resourceId
                LearnMoreUrl   = ($assessment.properties.links.azurePortal ?? '')
            })
        }
        $nextPath = ConvertTo-RestPath -NextLink ($assessmentPayload.nextLink ?? '')
    }
} catch {
    $statusCode = Get-ErrorStatusCode -ErrorRecord $_
    if ($statusCode -in @(404, 409)) {
        return [PSCustomObject]@{
            Source         = 'defender-for-cloud'
            Status         = 'Skipped'
            Message        = "Defender for Cloud assessments are unavailable for subscription $SubscriptionId"
            SubscriptionId = $SubscriptionId
            Findings       = @()
        }
    }
    Write-Warning "Defender assessments query failed: $_"
    return [PSCustomObject]@{
        Source         = 'defender-for-cloud'
        Status         = 'Failed'
        Message        = "$_"
        SubscriptionId = $SubscriptionId
        Findings       = @()
    }
}

return [PSCustomObject]@{
    Source         = 'defender-for-cloud'
    Status         = 'Success'
    Message        = ''
    SubscriptionId = $SubscriptionId
    Findings       = $findings.ToArray()
}
