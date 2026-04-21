#Requires -Version 7.4
<#
.SYNOPSIS
    Wrapper for Azure Quota Reports (az vm/network usage fanout).
.DESCRIPTION
    Enumerates subscriptions and locations, executes Azure CLI quota usage calls,
    and emits a v1 wrapper envelope with raw findings.
#>
[CmdletBinding()]
param (
    [string] $SubscriptionId,
    [string[]] $Subscriptions,
    [string[]] $Locations,
    [ValidateRange(1, 100)] [int] $Threshold = 80,
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

$installerPath = Join-Path $PSScriptRoot 'shared' 'Installer.ps1'
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    if (Test-Path $installerPath) { . $installerPath }
}
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param (
            [Parameter(Mandatory)][string]$Command,
            [Parameter(Mandatory)][string[]]$Arguments,
            [int]$TimeoutSec = 300
        )
        $output = & $Command @Arguments 2>&1 | Out-String
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
    }
}
if (-not (Get-Command New-InstallerError -ErrorAction SilentlyContinue)) {
    function New-InstallerError {
        param (
            [Parameter(Mandatory)][string] $Tool,
            [Parameter(Mandatory)][ValidateSet('psmodule','cli','gitclone','none')][string] $Kind,
            [Parameter(Mandatory)][string] $Reason,
            [string] $Package,
            [string] $Url,
            [string] $Remediation,
            [string] $Output,
            [string] $Category = 'InstallFailed'
        )
        return [PSCustomObject]@{
            Tool = $Tool
            Kind = $Kind
            Category = $Category
            Reason = $Reason
            Package = $Package
            Url = $Url
            Remediation = $Remediation
            Output = Remove-Credentials ([string]$Output)
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}

$result = [ordered]@{
    SchemaVersion = '1.0'
    Source        = 'azure-quota'
    Status        = 'Success'
    Message       = ''
    Findings      = @()
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
}

function Throw-QuotaFailure {
    param(
        [Parameter(Mandatory)][string] $Reason,
        [string] $Output = '',
        [string] $Category = 'ExecutionFailed',
        [string] $Remediation = 'Verify az login, Reader access, and subscription/region scope.'
    )
    $err = New-InstallerError -Tool 'azure-quota' -Kind 'cli' -Reason $Reason -Package 'az' -Category $Category -Remediation $Remediation -Output $Output
    throw ($err | ConvertTo-Json -Depth 8 -Compress)
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Context
    )

    $argsForAz = $Arguments + @('--output', 'json', '--only-show-errors')
    $exec = Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
        Invoke-WithTimeout -Command 'az' -Arguments $argsForAz -TimeoutSec 300
    }
    if (-not $exec -or $exec.ExitCode -ne 0) {
        $out = if ($exec) { [string]$exec.Output } else { '' }
        Throw-QuotaFailure -Reason "$Context failed." -Output $out
    }
    $raw = [string]$exec.Output
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try { return ($raw | ConvertFrom-Json -Depth 20) }
    catch { Throw-QuotaFailure -Reason "$Context returned invalid JSON." -Output $raw -Category 'ParseFailed' }
}

function Invoke-AzNoOutput {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Context
    )
    $argsForAz = $Arguments + @('--only-show-errors')
    $exec = Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 30 -ScriptBlock {
        Invoke-WithTimeout -Command 'az' -Arguments $argsForAz -TimeoutSec 300
    }
    if (-not $exec -or $exec.ExitCode -ne 0) {
        $out = if ($exec) { [string]$exec.Output } else { '' }
        Throw-QuotaFailure -Reason "$Context failed." -Output $out
    }
}

function Get-UsagePercent {
    param([double]$CurrentValue, [double]$Limit)
    if ($Limit -le 0) {
        if ($CurrentValue -gt 0) { return 100.0 }
        return 0.0
    }
    return [math]::Round(($CurrentValue / $Limit) * 100.0, 2)
}

function Get-SeverityFromPercent {
    param([double]$UsagePercent, [int]$ThresholdPercent)
    if ($UsagePercent -ge 95) { return 'Critical' }
    if ($UsagePercent -ge 90) { return 'High' }
    if ($UsagePercent -ge $ThresholdPercent) { return 'Medium' }
    return 'Low'
}

function Convert-UsageRowsToFindings {
    param(
        [Parameter(Mandatory)][object[]] $Rows,
        [Parameter(Mandatory)][string] $Subscription,
        [Parameter(Mandatory)][string] $SubscriptionName,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][int] $ThresholdPercent
    )

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        if (-not $row) { continue }
        $metricName = [string]$row.name?.value
        if ([string]::IsNullOrWhiteSpace($metricName)) {
            $metricName = [string]$row.name?.localizedValue
        }
        if ([string]::IsNullOrWhiteSpace($metricName)) { $metricName = 'unknown-metric' }

        $currentValue = [double]($row.currentValue ?? 0)
        $limit = [double]($row.limit ?? 0)
        $usagePercent = Get-UsagePercent -CurrentValue $currentValue -Limit $limit
        $compliant = ($usagePercent -lt $ThresholdPercent)
        $severity = Get-SeverityFromPercent -UsagePercent $usagePercent -ThresholdPercent $ThresholdPercent
        $safeMetric = (($metricName.ToLowerInvariant() -replace '[^a-z0-9._-]', '-').Trim('-'))
        if ([string]::IsNullOrWhiteSpace($safeMetric)) { $safeMetric = 'metric' }

        $items.Add([PSCustomObject]@{
                Id               = "azure-quota/$Subscription/$Location/$Service/$safeMetric"
                Source           = 'azure-quota'
                Category         = 'Capacity'
                Pillar           = 'Reliability'
                EntityType       = 'Subscription'
                Severity         = $severity
                Compliant        = $compliant
                Title            = "$Service quota usage for '$metricName' in $Location"
                Detail           = "Usage=$currentValue, Limit=$limit, UsagePercent=$usagePercent%, Threshold=$ThresholdPercent%."
                Remediation      = "Request quota increase or rebalance workload before usage reaches $ThresholdPercent%."
                ResourceId       = "/subscriptions/$Subscription"
                SubscriptionId   = $Subscription
                SubscriptionName = $SubscriptionName
                Location         = $Location
                Service          = $Service
                Sku              = $metricName
                MetricName       = $metricName
                Unit             = [string]($row.unit ?? '')
                CurrentValue     = $currentValue
                Limit            = $limit
                UsagePercent     = $usagePercent
                Threshold        = $ThresholdPercent
            }) | Out-Null
    }
    return @($items)
}

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        $result.Status = 'Skipped'
        $result.Message = 'Azure CLI (az) is not installed or not on PATH.'
        return [PSCustomObject]$result
    }

    $accounts = @(Invoke-AzJson -Arguments @('account', 'list') -Context 'az account list')
    $enabledAccounts = @($accounts | Where-Object { [string]$_.state -eq 'Enabled' })

    $subscriptionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($SubscriptionId) { $null = $subscriptionSet.Add($SubscriptionId) }
    foreach ($sub in @($Subscriptions)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$sub)) { $null = $subscriptionSet.Add([string]$sub) }
    }
    if ($subscriptionSet.Count -eq 0) {
        foreach ($acc in $enabledAccounts) {
            if ($acc.id) { $null = $subscriptionSet.Add([string]$acc.id) }
        }
    }

    $targetSubscriptions = @($subscriptionSet | Sort-Object)
    if (-not $targetSubscriptions -or $targetSubscriptions.Count -eq 0) {
        $result.Status = 'Skipped'
        $result.Message = 'No enabled subscriptions found for quota scan.'
        return [PSCustomObject]$result
    }

    $accountNameById = @{}
    foreach ($acc in $enabledAccounts) {
        if ($acc.id) { $accountNameById[[string]$acc.id] = [string]($acc.name ?? '') }
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($subId in $targetSubscriptions) {
        Invoke-AzNoOutput -Arguments @('account', 'set', '--subscription', $subId) -Context "az account set for subscription $subId"

        $subLocations = @()
        if ($Locations -and $Locations.Count -gt 0) {
            $subLocations = @($Locations | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        } else {
            $subLocations = @(Invoke-AzJson -Arguments @('account', 'list-locations', '--subscription', $subId, '--query', "[?metadata.regionType=='Physical'].name") -Context "az account list-locations for subscription $subId")
        }

        foreach ($location in @($subLocations)) {
            $locationName = [string]$location
            if ([string]::IsNullOrWhiteSpace($locationName)) { continue }

            $vmUsage = @(Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', $locationName, '--subscription', $subId) -Context "az vm list-usage ($subId/$locationName)")
            $netUsage = @(Invoke-AzJson -Arguments @('network', 'list-usages', '--location', $locationName, '--subscription', $subId) -Context "az network list-usages ($subId/$locationName)")

            foreach ($f in (Convert-UsageRowsToFindings -Rows $vmUsage -Subscription $subId -SubscriptionName $accountNameById[$subId] -Location $locationName -Service 'vm' -ThresholdPercent $Threshold)) {
                $findings.Add($f) | Out-Null
            }
            foreach ($f in (Convert-UsageRowsToFindings -Rows $netUsage -Subscription $subId -SubscriptionName $accountNameById[$subId] -Location $locationName -Service 'network' -ThresholdPercent $Threshold)) {
                $findings.Add($f) | Out-Null
            }
        }
    }

    $result.Findings = @($findings)
    $result.Message = "Processed $($targetSubscriptions.Count) subscription(s); emitted $($findings.Count) quota usage finding(s)."

    if ($OutputPath) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent -and -not (Test-Path $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        $serialized = ($result | ConvertTo-Json -Depth 20)
        [System.IO.File]::WriteAllText($OutputPath, (Remove-Credentials -Text $serialized))
    }

    return [PSCustomObject]$result
} catch {
    $result.Status = 'Failed'
    $result.Message = Remove-Credentials -Text ([string]$_.Exception.Message)
    $result.Findings = @()
    return [PSCustomObject]$result
}

