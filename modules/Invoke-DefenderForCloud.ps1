#requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Microsoft Defender for Cloud — per-subscription Secure Score + non-healthy assessments.

.DESCRIPTION
    Queries two REST endpoints under Microsoft.Security:
      - /providers/Microsoft.Security/secureScores/ascScore (current/max/percentage)
      - /providers/Microsoft.Security/assessments              (paged, filtered to non-healthy)

    Emits a v1 tool-result shape that the Normalize-DefenderForCloud normalizer downstream
    converts into v2 FindingRows. The Secure Score lands on the Subscription entity;
    each non-healthy assessment lands on its target AzureResource so the EntityStore folds
    the Defender recommendation next to existing azqr/PSRule findings on the same resource.

    Uses Invoke-WithRetry for transient 429/503/timeout handling. Gracefully skips when
    Defender for Cloud is not enabled on the subscription (404/Conflict on secureScores).

.PARAMETER SubscriptionId
    Azure subscription ID (GUID). Required.

.PARAMETER OutputPath
    Optional directory for raw API JSON (for audit).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry { param([scriptblock]$ScriptBlock, [int]$MaxAttempts = 3) & $ScriptBlock }
}

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'defender-for-cloud'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Subscription  = $SubscriptionId
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    $result.Status  = 'Skipped'
    $result.Message = 'Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    return [pscustomobject]$result
}
Import-Module Az.Accounts -ErrorAction SilentlyContinue

try {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No Az context' }
} catch {
    $result.Status  = 'Skipped'
    $result.Message = 'Not signed in. Run Connect-AzAccount first.'
    return [pscustomobject]$result
}

$findings = [System.Collections.Generic.List[object]]::new()

# --- 1. Secure Score (subscription-level roll-up) ---
$scoreUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/secureScores/ascScore?api-version=2020-01-01"
try {
    $scoreResp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
        Invoke-AzRestMethod -Method GET -Uri $using:scoreUri -ErrorAction Stop
    }
    if ($scoreResp -and $scoreResp.StatusCode -in 404, 409) {
        $result.Status  = 'Skipped'
        $result.Message = "Defender for Cloud not enabled on subscription (HTTP $($scoreResp.StatusCode))."
        return [pscustomobject]$result
    }
    if (-not $scoreResp -or $scoreResp.StatusCode -ge 400) {
        throw "Secure Score API returned status $($scoreResp.StatusCode): $($scoreResp.Content)"
    }
    $scoreBody = $scoreResp.Content | ConvertFrom-Json -Depth 20
    $current = [double]$scoreBody.properties.score.current
    $max     = [double]$scoreBody.properties.score.max
    $pct     = if ($max -gt 0) { [math]::Round(100.0 * $current / $max, 1) } else { 0.0 }

    $findings.Add([pscustomobject]@{
        Id           = "defender/securescore/$SubscriptionId"
        Source       = 'defender-for-cloud'
        Category     = 'SecurityPosture'
        Severity     = 'Info'
        Compliant    = $true
        Title        = "Defender Secure Score: $current / $max ($pct%)"
        Detail       = "Secure Score for subscription $SubscriptionId. Current=$current, Max=$max, Percentage=$pct%."
        ResourceId   = "/subscriptions/$SubscriptionId"
        ResourceType = 'Microsoft.Resources/subscriptions'
        ScoreCurrent = $current
        ScoreMax     = $max
        ScorePercent = $pct
        LearnMoreUrl = 'https://learn.microsoft.com/azure/defender-for-cloud/secure-score-security-controls'
    }) | Out-Null
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Secure Score query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [pscustomobject]$result
}

# --- 2. Assessments (resource-level recommendations) ---
$assessUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/assessments?api-version=2020-01-01"
$nextLink  = $assessUri
$pageCount = 0
$maxPages  = 20
$nonHealthy = 0

try {
    while ($nextLink -and $pageCount -lt $maxPages) {
        $pageCount++
        $resp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
            Invoke-AzRestMethod -Method GET -Uri $using:nextLink -ErrorAction Stop
        }
        if (-not $resp -or $resp.StatusCode -ge 400) {
            if ($resp -and $resp.StatusCode -in 404) { break }
            throw "Assessments API returned status $($resp.StatusCode): $($resp.Content)"
        }
        $body = $resp.Content | ConvertFrom-Json -Depth 20
        if ($body.value) {
            foreach ($a in $body.value) {
                $statusCode = ''
                try { $statusCode = [string]$a.properties.status.code } catch {}
                if ($statusCode -ne 'Unhealthy') { continue }
                $nonHealthy++

                $rid = ''
                try { $rid = [string]$a.properties.resourceDetails.id } catch {}
                if (-not $rid) { $rid = "/subscriptions/$SubscriptionId" }

                $displayName = ''
                $sev         = 'Medium'
                $description = ''
                $remediation = ''
                try { $displayName = [string]$a.properties.displayName } catch {}
                try { $sev         = [string]$a.properties.metadata.severity } catch {}
                try { $description = [string]$a.properties.metadata.description } catch {}
                try { $remediation = [string]$a.properties.metadata.remediationDescription } catch {}
                if (-not $sev) { $sev = 'Medium' }

                $findings.Add([pscustomobject]@{
                    Id           = "defender/assessment/$($a.name)/$rid"
                    Source       = 'defender-for-cloud'
                    Category     = 'SecurityPosture'
                    Severity     = $sev
                    Compliant    = $false
                    Title        = $displayName
                    Detail       = $description
                    Remediation  = $remediation
                    ResourceId   = $rid
                    AssessmentId = [string]$a.name
                    LearnMoreUrl = 'https://learn.microsoft.com/azure/defender-for-cloud/review-security-recommendations'
                }) | Out-Null
            }
        }
        $nextLink = $body.nextLink
    }
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Assessments query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [pscustomobject]$result
}

$result.Findings = @($findings)
$result.Message  = "Emitted Secure Score + $nonHealthy non-healthy recommendations."

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $raw = Join-Path $OutputPath "defender-$SubscriptionId-$(Get-Date -Format yyyyMMddHHmmss).json"
        (Remove-Credentials ($result | ConvertTo-Json -Depth 20)) | Set-Content -Path $raw -Encoding utf8
    } catch {
        Write-Warning "Failed to write raw Defender JSON: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [pscustomobject]$result
