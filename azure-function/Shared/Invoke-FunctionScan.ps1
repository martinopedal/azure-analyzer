#Requires -Version 7.4
<#
.SYNOPSIS
    Shared scan entrypoint used by the TimerScan and HttpScan Function triggers.
.DESCRIPTION
    Resolves scan parameters from environment variables (TimerScan) or an
    HTTP request body (HttpScan), invokes the orchestrator with a bounded
    toolset, and -- when DCE_ENDPOINT is configured -- forwards entities.json
    to the existing Log Analytics sink (modules/sinks/Send-FindingsToLogAnalytics.ps1).

    No new sink module is introduced; this is a thin wrapper around the
    orchestrator + the LogAnalytics sink contract from #162.

    All persisted error text is sanitized via Remove-Credentials.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')

$sanitizePath = Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

$sinkPath = Join-Path $script:RepoRoot 'modules' 'sinks' 'Send-FindingsToLogAnalytics.ps1'
if (Test-Path $sinkPath) { . $sinkPath }

# Allow-list of tool names accepted from untrusted HTTP input. Keeping it
# tight prevents request-driven scope creep and aligns with the manifest.
$script:AllowedTools = @(
    'azqr', 'psrule', 'alz-queries', 'wara',
    'azure-cost', 'finops', 'defender-for-cloud',
    'sentinel-incidents', 'sentinel-coverage',
    'maester', 'identity-correlator'
)

function ConvertTo-AllowedToolList {
    [CmdletBinding()]
    param ([object] $Value)

    if ($null -eq $Value) { return @() }

    $candidates = @()
    if ($Value -is [string]) {
        $candidates = $Value -split '[,;\s]+' | Where-Object { $_ }
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        $candidates = @($Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
    } else {
        $candidates = @([string]$Value) | Where-Object { $_ }
    }

    $bad = @($candidates | Where-Object { $_ -notin $script:AllowedTools })
    if ($bad.Count -gt 0) {
        throw "Tool(s) not allowed from request input: $($bad -join ', '). Allowed: $($script:AllowedTools -join ', ')."
    }
    return @($candidates | Select-Object -Unique)
}

function Resolve-RunId {
    param ([string] $Suffix)
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    if ([string]::IsNullOrWhiteSpace($Suffix)) { return $stamp }
    return "$stamp-$Suffix"
}

function Invoke-FunctionScan {
    [CmdletBinding()]
    param (
        [hashtable] $RequestBody = @{},

        [string] $TriggerName = 'timer',

        [hashtable] $EnvOverride
    )

    # Indirect env access so tests can inject a fake env hashtable.
    $envSource = if ($EnvOverride) { $EnvOverride } else {
        $h = @{}
        foreach ($k in @(
            'AZURE_ANALYZER_SUBSCRIPTION_ID', 'AZURE_ANALYZER_TENANT_ID',
            'AZURE_ANALYZER_INCLUDE_TOOLS', 'AZURE_ANALYZER_OUTPUT_PATH',
            'DCE_ENDPOINT', 'DCR_IMMUTABLE_ID',
            'FINDINGS_STREAM', 'ENTITIES_STREAM', 'SINK_DRY_RUN'
        )) {
            $v = [System.Environment]::GetEnvironmentVariable($k)
            if ($null -ne $v) { $h[$k] = $v }
        }
        $h
    }

    $subscriptionId = if ($RequestBody.ContainsKey('subscriptionId') -and $RequestBody.subscriptionId) {
        [string]$RequestBody.subscriptionId
    } else {
        [string]$envSource['AZURE_ANALYZER_SUBSCRIPTION_ID']
    }
    $tenantId = if ($RequestBody.ContainsKey('tenantId') -and $RequestBody.tenantId) {
        [string]$RequestBody.tenantId
    } else {
        [string]$envSource['AZURE_ANALYZER_TENANT_ID']
    }

    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "subscriptionId is required (set AZURE_ANALYZER_SUBSCRIPTION_ID or pass subscriptionId in the request body)."
    }
    if ($subscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "subscriptionId is not a valid GUID."
    }
    if ($tenantId -and $tenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "tenantId is not a valid GUID."
    }

    $rawTools = if ($RequestBody.ContainsKey('includeTools') -and $RequestBody.includeTools) {
        $RequestBody.includeTools
    } else {
        $envSource['AZURE_ANALYZER_INCLUDE_TOOLS']
    }
    $includeTools = @(ConvertTo-AllowedToolList -Value $rawTools)

    $runId = Resolve-RunId -Suffix $TriggerName
    $outputBase = if ($envSource.ContainsKey('AZURE_ANALYZER_OUTPUT_PATH') -and $envSource['AZURE_ANALYZER_OUTPUT_PATH']) {
        [string]$envSource['AZURE_ANALYZER_OUTPUT_PATH']
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'azure-analyzer'
    }
    $outputPath = Join-Path $outputBase $runId
    [void](New-Item -ItemType Directory -Force -Path $outputPath)

    $analyzerScript = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
    if (-not (Test-Path $analyzerScript)) {
        throw "Invoke-AzureAnalyzer.ps1 not found at $analyzerScript."
    }

    $analyzerArgs = @{
        SubscriptionId = $subscriptionId
        OutputPath     = $outputPath
        SkipPrereqCheck = $true
    }
    if ($tenantId) { $analyzerArgs['TenantId'] = $tenantId }
    if ($includeTools.Count -gt 0) { $analyzerArgs['IncludeTools'] = $includeTools }

    $entitiesPath = Join-Path $outputPath 'entities.json'

    try {
        & $analyzerScript @analyzerArgs | Out-Null
    } catch {
        $msg = Remove-Credentials "$_"
        throw "Orchestrator run failed (runId=$runId): $msg"
    }

    $sinkResult = $null
    $dceEndpoint = [string]$envSource['DCE_ENDPOINT']
    $dcrId       = [string]$envSource['DCR_IMMUTABLE_ID']
    if (-not [string]::IsNullOrWhiteSpace($dceEndpoint) -and -not [string]::IsNullOrWhiteSpace($dcrId)) {
        if (-not (Test-Path $entitiesPath)) {
            Write-Warning "[function] entities.json missing at $entitiesPath; skipping sink."
        } elseif (-not (Get-Command Send-FindingsToLogAnalytics -ErrorAction SilentlyContinue)) {
            Write-Warning "[function] Log Analytics sink module not loaded; skipping sink."
        } else {
            $findingsStream = if ($envSource['FINDINGS_STREAM']) { [string]$envSource['FINDINGS_STREAM'] } else { 'Custom-AzureAnalyzerFindings' }
            $entitiesStream = if ($envSource['ENTITIES_STREAM']) { [string]$envSource['ENTITIES_STREAM'] } else { 'Custom-AzureAnalyzerEntities' }
            $dryRun = $false
            if ($envSource['SINK_DRY_RUN']) {
                $dryRun = ([string]$envSource['SINK_DRY_RUN']) -in @('1', 'true', 'True', 'yes', 'on')
            }

            try {
                $sinkResult = [pscustomobject]@{
                    Findings = Send-FindingsToLogAnalytics -EntitiesJson $entitiesPath -DceEndpoint $dceEndpoint -DcrImmutableId $dcrId -StreamName $findingsStream -DryRun:$dryRun
                    Entities = Send-EntitiesToLogAnalytics -EntitiesJson $entitiesPath -DceEndpoint $dceEndpoint -DcrImmutableId $dcrId -StreamName $entitiesStream -DryRun:$dryRun
                }
            } catch {
                $msg = Remove-Credentials "$_"
                # Sink failure does NOT fail the scan (matches orchestrator -SinkLogAnalytics behavior).
                Write-Warning "[function] Log Analytics sink upload failed: $msg"
                $sinkResult = [pscustomobject]@{ Error = $msg }
            }
        }
    }

    return [pscustomobject]@{
        RunId        = $runId
        Trigger      = $TriggerName
        OutputPath   = $outputPath
        EntitiesPath = $entitiesPath
        Sink         = $sinkResult
    }
}
