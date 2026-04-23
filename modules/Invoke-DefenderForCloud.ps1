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

$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
}

$toolVersion = 'microsoft.security/rest-2020-01-01+2022-01-01-preview'

function ConvertTo-StringArray {
    param (
        [AllowNull()]
        [object] $Value
    )
    if ($null -eq $Value) { return @() }
    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            foreach ($part in ($item -split '[,;]')) {
                $v = $part.Trim()
                if ($v) { $items.Add($v) | Out-Null }
            }
            continue
        }
        $s = [string]$item
        if ($s) { $items.Add($s.Trim()) | Out-Null }
    }
    return @($items | Sort-Object -Unique)
}

function Get-FrameworksFromObject {
    param (
        [AllowNull()]
        [object] $InputObject
    )
    if ($null -eq $InputObject) { return @() }

    try {
        $json = $InputObject | ConvertTo-Json -Depth 30 -Compress
    } catch {
        $json = [string]$InputObject
    }
    if (-not $json) { return @() }

    $out = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $kinds = @(
        @{ Kind = 'MCSB'; Pattern = '(?i)\b(mcsb|microsoft cloud security benchmark)\b' },
        @{ Kind = 'ISO27001'; Pattern = '(?i)\biso[\s-]?27001\b' },
        @{ Kind = 'PCI'; Pattern = '(?i)\bpci(\s*dss)?\b' },
        @{ Kind = 'CIS'; Pattern = '(?i)\bcis\b' },
        @{ Kind = 'NIST'; Pattern = '(?i)\bnist\b' },
        @{ Kind = 'SOC2'; Pattern = '(?i)\bsoc[\s-]?2\b' }
    )

    foreach ($k in $kinds) {
        if ($json -match $k.Pattern) {
            $token = "$($k.Kind)|"
            if ($seen.Add($token)) {
                $out.Add(@{ kind = $k.Kind; controlId = '' }) | Out-Null
            }
        }
    }

    foreach ($m in [regex]::Matches($json, '(?i)\bMCSB[-\s:_]*([A-Za-z0-9\.\-]+)\b')) {
        $cid = [string]$m.Groups[1].Value
        if (-not $cid) { continue }
        $token = "MCSB|$cid"
        if ($seen.Add($token)) {
            $out.Add(@{ kind = 'MCSB'; controlId = $cid }) | Out-Null
        }
    }

    return @($out)
}

function Get-UriStringsFromObject {
    param (
        [AllowNull()]
        [object] $InputObject
    )
    if ($null -eq $InputObject) { return @() }

    try {
        $json = $InputObject | ConvertTo-Json -Depth 30 -Compress
    } catch {
        $json = [string]$InputObject
    }
    if (-not $json) { return @() }

    $matches = [regex]::Matches($json, '(?i)https://[^"''\s\\]+')
    $uris = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $matches) {
        $u = [string]$m.Value
        if ($u) { $uris.Add($u) | Out-Null }
    }
    return @($uris | Sort-Object -Unique)
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
    if (-not $ctx) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:defender-for-cloud' -Category 'AuthenticationFailed' -Reason 'No Az context.' -Remediation 'Run Connect-AzAccount and select the target subscription context.'))
    }
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
        Invoke-AzRestMethod -Method GET -Uri $scoreUri -ErrorAction Stop
    }
    if ($scoreResp -and $scoreResp.StatusCode -in 404, 409) {
        $result.Status  = 'Skipped'
        $result.Message = "Defender for Cloud not enabled on subscription (HTTP $($scoreResp.StatusCode))."
        return [pscustomobject]$result
    }
    if (-not $scoreResp -or $scoreResp.StatusCode -ge 400) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:defender-for-cloud' -Category 'UnexpectedFailure' -Reason "Secure Score API returned status $($scoreResp.StatusCode)." -Remediation 'Verify Defender for Cloud API access and rerun the scan.' -Details ([string]$scoreResp.Content)))
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
        Pillar       = 'Security'
        ToolVersion  = $toolVersion
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
$alertCount = 0

try {
    while ($nextLink -and $pageCount -lt $maxPages) {
        $pageCount++
        $resp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
            Invoke-AzRestMethod -Method GET -Uri $nextLink -ErrorAction Stop
        }
        if (-not $resp -or $resp.StatusCode -ge 400) {
            if ($resp -and $resp.StatusCode -in 404) { break }
            throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:defender-for-cloud' -Category 'UnexpectedFailure' -Reason "Assessments API returned status $($resp.StatusCode)." -Remediation 'Verify Microsoft.Security assessment API access and rerun the scan.' -Details ([string]$resp.Content)))
        }
        $body = $resp.Content | ConvertFrom-Json -Depth 20
        $items = @()
        try { $items = @($body.value) } catch { $items = @() }
        if ($items.Count -gt 0) {
            foreach ($a in $items) {
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

                $deepLink = ''
                try { $deepLink = [string]$a.properties.links.azurePortal } catch {}
                if (-not $deepLink) {
                    $deepLink = "https://portal.azure.com/#view/Microsoft_Azure_Security/RecommendationsBlade/assessmentKey/$([uri]::EscapeDataString([string]$a.name))"
                }

                $metadata = $null
                $additionalData = $null
                $regulatoryStandards = $null
                try { $metadata = $a.properties.metadata } catch {}
                try { $additionalData = $a.properties.additionalData } catch {}
                try { $regulatoryStandards = $additionalData.regulatoryComplianceStandards } catch {}

                $frameworks = Get-FrameworksFromObject -InputObject @($metadata, $additionalData, $regulatoryStandards)
                $evidenceUris = @($deepLink) + (Get-UriStringsFromObject -InputObject $additionalData)
                $evidenceUris = @($evidenceUris | Where-Object { $_ } | Sort-Object -Unique)

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
                    RuleId       = [string]$a.name
                    Pillar       = 'Security'
                    Frameworks   = @($frameworks)
                    DeepLinkUrl  = $deepLink
                    EvidenceUris = @($evidenceUris)
                    ToolVersion  = $toolVersion
                    LearnMoreUrl = 'https://learn.microsoft.com/azure/defender-for-cloud/review-security-recommendations'
                }) | Out-Null
            }
        }
        $nextLink = $null
        try { $nextLink = [string]$body.nextLink } catch {}
        if (-not $nextLink) { $nextLink = $null }
    }
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Assessments query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [pscustomobject]$result
}

$alertsUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/alerts?api-version=2022-01-01-preview"
$alertsNext = $alertsUri
$alertsPages = 0
try {
    while ($alertsNext -and $alertsPages -lt $maxPages) {
        $alertsPages++
        $resp = Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
            Invoke-AzRestMethod -Method GET -Uri $alertsNext -ErrorAction Stop
        }
        if (-not $resp -or $resp.StatusCode -ge 400) {
            if ($resp -and $resp.StatusCode -in 404) { break }
            throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:defender-for-cloud' -Category 'UnexpectedFailure' -Reason "Alerts API returned status $($resp.StatusCode)." -Remediation 'Verify Microsoft.Security alerts API access and rerun the scan.' -Details ([string]$resp.Content)))
        }

        $body = $resp.Content | ConvertFrom-Json -Depth 30
        $alertItems = @()
        try { $alertItems = @($body.value) } catch { $alertItems = @() }
        foreach ($a in $alertItems) {
            $status = ''
            try { $status = [string]$a.properties.status } catch {}
            if ($status -match '^(?i)(dismissed|resolved)$') { continue }

            $rid = ''
            try { $rid = [string]$a.properties.resourceIdentifiers.AzureResourceId } catch {}
            if (-not $rid) {
                try { $rid = [string]$a.properties.compromisedEntity } catch {}
            }
            if (-not $rid -or $rid -notmatch '^/subscriptions/') { $rid = "/subscriptions/$SubscriptionId" }

            $sev = 'Medium'
            try { $sev = [string]$a.properties.severity } catch {}
            if (-not $sev) { $sev = 'Medium' }

            $title = ''
            try { $title = [string]$a.properties.alertDisplayName } catch {}
            if (-not $title) { try { $title = [string]$a.properties.displayName } catch {} }
            if (-not $title) { $title = 'Defender alert' }

            $detail = ''
            try { $detail = [string]$a.properties.description } catch {}
            if (-not $detail) { try { $detail = [string]$a.properties.extendedProperties.description } catch {} }

            $alertArmId = ''
            try { $alertArmId = [string]$a.id } catch {}
            $deepLink = ''
            if ($alertArmId) {
                $deepLink = "https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityMenuBlade/~/0/id/$([uri]::EscapeDataString($alertArmId))"
            }

            $mitreTactics = @()
            $mitreTechniques = @()
            try { $mitreTactics = ConvertTo-StringArray -Value $a.properties.tactics } catch {}
            if (-not $mitreTactics) { try { $mitreTactics = ConvertTo-StringArray -Value $a.properties.extendedProperties.Tactics } catch {} }
            try { $mitreTechniques = ConvertTo-StringArray -Value $a.properties.techniques } catch {}
            if (-not $mitreTechniques) { try { $mitreTechniques = ConvertTo-StringArray -Value $a.properties.extendedProperties.Techniques } catch {} }

            $extendedProperties = $null
            try { $extendedProperties = $a.properties.extendedProperties } catch {}
            $frameworks = Get-FrameworksFromObject -InputObject @($a.properties, $extendedProperties)
            $evidenceUris = @(Get-UriStringsFromObject -InputObject @($a.properties, $extendedProperties))
            if ($deepLink) { $evidenceUris = @($evidenceUris + @($deepLink) | Sort-Object -Unique) }

            $alertName = ''
            try { $alertName = [string]$a.name } catch {}
            if (-not $alertName) { $alertName = [guid]::NewGuid().ToString() }

            $findings.Add([pscustomobject]@{
                    Id              = "defender/alert/$alertName/$rid"
                    Source          = 'defender-for-cloud'
                    Category        = 'ThreatDetection'
                    Severity        = $sev
                    Compliant       = $false
                    Title           = $title
                    Detail          = $detail
                    Remediation     = ''
                    ResourceId      = $rid
                    AlertId         = $alertName
                    RuleId          = $alertName
                    Pillar          = 'Security'
                    Frameworks      = @($frameworks)
                    DeepLinkUrl     = $deepLink
                    EvidenceUris    = @($evidenceUris)
                    MitreTactics    = @($mitreTactics)
                    MitreTechniques = @($mitreTechniques)
                    ToolVersion     = $toolVersion
                    LearnMoreUrl    = 'https://learn.microsoft.com/azure/defender-for-cloud/alerts-overview'
                }) | Out-Null
            $alertCount++
        }
        $alertsNext = $null
        try { $alertsNext = [string]$body.nextLink } catch {}
        if (-not $alertsNext) { $alertsNext = $null }
    }
} catch {
    $result.Status  = 'Failed'
    $result.Message = "Alerts query failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    return [pscustomobject]$result
}

$result.Findings = @($findings)
$result.Message  = "Emitted Secure Score + $nonHealthy non-healthy recommendations + $alertCount active alerts."

if ($OutputPath) {
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $raw = Join-Path $OutputPath "defender-$SubscriptionId-$(Get-Date -Format yyyyMMddHHmmss).json"
        Set-Content -Path $raw -Value (Remove-Credentials ($result | ConvertTo-Json -Depth 20)) -Encoding utf8
    } catch {
        Write-Warning "Failed to write raw Defender JSON: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
    }
}

return [pscustomobject]$result
