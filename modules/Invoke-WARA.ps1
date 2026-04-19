#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for the Well-Architected Reliability Assessment (WARA) collector.
.DESCRIPTION
    Installs/imports the WARA module if needed, runs Start-WARACollector for the
    given subscription, parses the output JSON, and returns findings as PSObjects.
    Gracefully degrades if WARA is not available or collector fails.
.PARAMETER SubscriptionId
    Azure subscription ID (without /subscriptions/ prefix).
.PARAMETER TenantId
    Azure tenant ID. Defaults to current Az context tenant if not specified.
.PARAMETER OutputPath
    Directory to write WARA collector JSON. Defaults to .\output\wara.
.EXAMPLE
    .\Invoke-WARA.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [string] $TenantId,
    [string] $OutputPath = (Join-Path $PSScriptRoot '..\output\wara')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

# Check WARA module is available (centralized Install-Prerequisites handles installation)
if (-not (Get-Module -ListAvailable -Name WARA)) {
    Write-Warning "WARA module not found. Install with: Install-Module WARA -Scope CurrentUser"
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Skipped'; Message = 'WARA module not installed. Run: Install-Module WARA -Scope CurrentUser'; Findings = @() }
}

Import-Module WARA -ErrorAction SilentlyContinue
if (-not (Get-Command Start-WARACollector -ErrorAction SilentlyContinue)) {
    Write-Warning "WARA module loaded but Start-WARACollector not found. Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Skipped'; Message = 'Could not install WARA module'; Findings = @() }
}

# Resolve tenant
if (-not $TenantId) {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $TenantId = if ($null -ne $ctx -and $null -ne $ctx.Tenant) { $ctx.Tenant.Id } else { $null }
    if (-not $TenantId) {
        Write-Warning "No TenantId provided and no Az context found. Returning empty result."
        return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = 'No TenantId and no Az context'; Findings = @() }
    }
}

# Ensure output dir
if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

# Run collector
$subArg = "/subscriptions/$SubscriptionId"
try {
    Push-Location $OutputPath
    Start-WARACollector -TenantID $TenantId -SubscriptionIds $subArg -ErrorAction Stop
    Pop-Location
} catch {
    Pop-Location
    Write-Warning "WARA collector failed: $(Remove-Credentials -Text ([string]$_)). Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = (Remove-Credentials -Text ([string]$_)); Findings = @() }
}

# Find the newest JSON output file
$jsonFile = Get-ChildItem -Path $OutputPath -Filter "WARA_File_*.json" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $jsonFile) {
    Write-Warning "WARA collector ran but no output JSON found in $OutputPath."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = 'No output JSON produced'; Findings = @() }
}

# Parse findings
try {
    $raw = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Warning "Could not parse WARA JSON: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Failed'; Message = (Remove-Credentials -Text "JSON parse error: $([string]$_)"); Findings = @() }
}

# Map to flat finding objects — WARA JSON has a 'ImpactedResources' or 'Recommendations' array
# Handle both known WARA output shapes gracefully
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

$recommendations = $raw.Recommendations ?? ($raw.PSObject.Properties.Value | Where-Object { $_ -is [array] } | Select-Object -First 1)
foreach ($rec in $recommendations) {
    # Extract resource ID from ImpactedResources or ResourceId fields
    $resId = $rec.ResourceId ?? ''
    if (-not $resId -and $rec.PSObject.Properties['ImpactedResources']) {
        $first = @($rec.ImpactedResources) | Select-Object -First 1
        if ($first) { $resId = $first.ResourceId ?? $first.Id ?? $first ?? '' }
    }
    $findings.Add([PSCustomObject]@{
        Id           = $rec.GUID ?? [guid]::NewGuid().ToString()
        Category     = $rec.Category ?? $rec.Service ?? 'Reliability'
        Title        = $rec.Recommendation ?? $rec.Title ?? 'Unknown'
        Severity     = $rec.Impact ?? $rec.Severity ?? 'Medium'
        Compliant    = $false  # WARA only emits non-compliant findings
        Detail       = $rec.Description ?? $rec.LongDescription ?? ''
        Remediation  = $rec.LearnMoreLink ?? $rec.Link ?? ''
        ResourceId   = [string]$resId
        LearnMoreUrl = $rec.LearnMoreLink ?? $rec.Link ?? ''
    })
}

return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'wara'; Status = 'Success'; Message = ''; Findings = $findings }
