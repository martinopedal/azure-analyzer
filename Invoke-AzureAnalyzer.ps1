#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Analyzer — unified Azure assessment orchestrator.
.DESCRIPTION
    Calls all five assessment tool wrappers (azqr, PSRule, AzGovViz, alz-queries, WARA),
    merges results into a unified schema, and writes output/results.json.
    At least one of -SubscriptionId or -ManagementGroupId is required.
    Tools that are not installed are skipped gracefully.
.PARAMETER SubscriptionId
    Azure subscription ID. Used by azqr, PSRule (live), alz-queries, and WARA.
.PARAMETER ManagementGroupId
    Management group ID. Used by AzGovViz and alz-queries.
.PARAMETER TenantId
    Azure tenant ID. Used by WARA collector. Defaults to current Az context tenant.
.PARAMETER OutputPath
    Output directory for results.json. Defaults to .\output.
.EXAMPLE
    .\Invoke-AzureAnalyzer.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
    .\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ManagementGroupId "my-mg"
    .\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -TenantId "..."
#>
[CmdletBinding()]
param (
    [string] $SubscriptionId,
    [string] $ManagementGroupId,
    [string] $TenantId,
    [string] $Repository,
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $SubscriptionId -and -not $ManagementGroupId) {
    throw "At least one of -SubscriptionId or -ManagementGroupId is required."
}

$modulesPath = Join-Path $PSScriptRoot 'modules'

function Invoke-Wrapper {
    param ([string]$Script, [hashtable]$Params)
    $scriptPath = Join-Path $modulesPath $Script
    if (-not (Test-Path $scriptPath)) {
        Write-Warning "$Script not found at $scriptPath"
        return [PSCustomObject]@{ Source = $Script; Findings = @() }
    }
    try {
        return & $scriptPath @Params
    } catch {
        Write-Warning "$Script threw an unexpected error: $_"
        return [PSCustomObject]@{ Source = $Script; Findings = @() }
    }
}

function Map-Severity {
    param ([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return 'Info' }
    switch -Regex ($Raw.ToLowerInvariant()) {
        'high|critical'   { return 'High' }
        'medium|moderate' { return 'Medium' }
        'low'             { return 'Low' }
        default           { return 'Info' }
    }
}

function Get-Prop {
    param ($Obj, [string]$Name, $Default = '')
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

Write-Host "=== Azure Analyzer ===" -ForegroundColor Cyan

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- azqr ---
if ($SubscriptionId) {
    Write-Host "`n[1/5] Running azqr..." -ForegroundColor Yellow
    $azqrResult = Invoke-Wrapper -Script 'Invoke-Azqr.ps1' -Params @{ SubscriptionId = $SubscriptionId }
    foreach ($f in $azqrResult.Findings) {
        $allResults.Add([PSCustomObject]@{
            Id           = [guid]::NewGuid().ToString()
            Source       = 'azqr'
            Category     = Get-Prop $f 'Category' (Get-Prop $f 'ServiceCategory' 'General')
            Title        = Get-Prop $f 'Recommendation' (Get-Prop $f 'Description' ($f | ConvertTo-Json -Compress -ErrorAction SilentlyContinue))
            Severity     = Map-Severity (Get-Prop $f 'Severity' (Get-Prop $f 'Risk' 'Info'))
            Compliant    = ((Get-Prop $f 'Result') -eq 'OK') -or ((Get-Prop $f 'Compliant') -eq $true)
            Detail       = Get-Prop $f 'Notes' (Get-Prop $f 'Description' '')
            Remediation  = Get-Prop $f 'Url' ''
            ResourceId   = Get-Prop $f 'ResourceId' (Get-Prop $f 'Id' '')
            LearnMoreUrl = Get-Prop $f 'LearnMoreLink' (Get-Prop $f 'Url' '')
        })
    }
    Write-Host "  azqr: $($azqrResult.Findings.Count) findings" -ForegroundColor Gray
}

# --- PSRule ---
Write-Host "`n[2/5] Running PSRule..." -ForegroundColor Yellow
$psruleParams = if ($SubscriptionId) { @{ SubscriptionId = $SubscriptionId } } else { @{ Path = '.' } }
$psruleResult = Invoke-Wrapper -Script 'Invoke-PSRule.ps1' -Params $psruleParams
foreach ($f in $psruleResult.Findings) {
    $allResults.Add([PSCustomObject]@{
        Id           = [guid]::NewGuid().ToString()
        Source       = 'psrule'
        Category     = Get-Prop $f 'RuleName' 'PSRule'
        Title        = Get-Prop $f 'RuleName' 'Unknown rule'
        Severity     = Map-Severity (Get-Prop $f 'Outcome' 'Info')
        Compliant    = (Get-Prop $f 'Outcome') -eq 'Pass'
        Detail       = Get-Prop $f 'Message' (Get-Prop $f 'TargetName' '')
        Remediation  = ''
        ResourceId   = Get-Prop $f 'ResourceId' ''
        LearnMoreUrl = Get-Prop $f 'LearnMoreUrl' ''
    })
}
Write-Host "  PSRule: $($psruleResult.Findings.Count) findings" -ForegroundColor Gray

# --- AzGovViz ---
if ($ManagementGroupId) {
    Write-Host "`n[3/5] Running AzGovViz..." -ForegroundColor Yellow
    $azgovvizResult = Invoke-Wrapper -Script 'Invoke-AzGovViz.ps1' -Params @{ ManagementGroupId = $ManagementGroupId }
    foreach ($f in $azgovvizResult.Findings) {
        $allResults.Add([PSCustomObject]@{
            Id           = [guid]::NewGuid().ToString()
            Source       = 'azgovviz'
            Category     = Get-Prop $f 'Category' 'Governance'
            Title        = Get-Prop $f 'Title' (Get-Prop $f 'Description' ($f | ConvertTo-Json -Compress -ErrorAction SilentlyContinue))
            Severity     = Map-Severity (Get-Prop $f 'Severity' 'Info')
            Compliant    = if ($null -eq $f.PSObject.Properties['Compliant']) { $true } else { (Get-Prop $f 'Compliant') -ne $false }
            Detail       = Get-Prop $f 'Detail' ''
            Remediation  = Get-Prop $f 'Remediation' ''
            ResourceId   = Get-Prop $f 'ResourceId' ''
            LearnMoreUrl = Get-Prop $f 'LearnMoreUrl' (Get-Prop $f 'LearnMoreLink' '')
        })
    }
    Write-Host "  AzGovViz: $($azgovvizResult.Findings.Count) findings" -ForegroundColor Gray
} else {
    Write-Host "`n[3/5] Skipping AzGovViz (no ManagementGroupId provided)" -ForegroundColor DarkGray
}

# --- ALZ Queries ---
if (ShouldRunTool 'alz-queries') {
    Write-Host "`n[4/7] Running ALZ queries..." -ForegroundColor Yellow
    $alzParams = if ($ManagementGroupId) {
        @{ ManagementGroupId = $ManagementGroupId }
    } else {
        @{ SubscriptionId = $SubscriptionId }
    }
    $alzResult = Invoke-Wrapper -Script 'Invoke-AlzQueries.ps1' -Params $alzParams
    foreach ($f in $alzResult.Findings) {
        $allResults.Add([PSCustomObject]@{
            Id           = Get-Prop $f 'Id' ([guid]::NewGuid().ToString())
            Source       = 'alz-queries'
            Category     = Get-Prop $f 'Category' 'ALZ'
            Title        = Get-Prop $f 'Title' 'Unknown'
            Severity     = Map-Severity (Get-Prop $f 'Severity' 'Medium')
            Compliant    = $f.Compliant
            Detail       = Get-Prop $f 'Detail' ''
            Remediation  = ''
            ResourceId   = Get-Prop $f 'ResourceId' ''
            LearnMoreUrl = Get-Prop $f 'LearnMoreUrl' ''
        })
    }
    Write-Host "  ALZ queries: $($alzResult.Findings.Count) findings" -ForegroundColor Gray
} else {
    Write-Host "`n[4/7] Skipping ALZ queries (excluded)" -ForegroundColor DarkGray
}

# --- WARA ---
if (ShouldRunTool 'wara') {
    if ($SubscriptionId) {
        Write-Host "`n[5/7] Running WARA..." -ForegroundColor Yellow
        $waraParams = @{ SubscriptionId = $SubscriptionId; OutputPath = (Join-Path $OutputPath 'wara') }
        if ($TenantId) { $waraParams['TenantId'] = $TenantId }
        $waraResult = Invoke-Wrapper -Script 'Invoke-WARA.ps1' -Params $waraParams
        foreach ($f in $waraResult.Findings) {
            $allResults.Add([PSCustomObject]@{
                Id           = $f.Id ?? [guid]::NewGuid().ToString()
                Source       = 'wara'
                Category     = $f.Category ?? 'Reliability'
                Title        = $f.Title ?? 'Unknown'
                Severity     = Map-Severity ($f.Severity ?? 'Medium')
                Compliant    = $f.Compliant
                Detail       = $f.Detail ?? ''
                Remediation  = $f.Remediation ?? ''
                ResourceId   = $f.ResourceId ?? ''
                LearnMoreUrl = $f.LearnMoreUrl ?? ''
            })
        }
        Write-Host "  WARA: $($waraResult.Findings.Count) findings" -ForegroundColor Gray
    } else {
        Write-Host "`n[5/7] Skipping WARA (no SubscriptionId provided)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "`n[5/7] Skipping WARA (excluded)" -ForegroundColor DarkGray
}

# --- Maester ---
if (ShouldRunTool 'maester') {
    Write-Host "`n[6/7] Running Maester..." -ForegroundColor Yellow
    $maesterResult = Invoke-Wrapper -Script 'Invoke-Maester.ps1' -Params @{}
    foreach ($f in $maesterResult.Findings) {
        $allResults.Add([PSCustomObject]@{
            Id           = $f.Id ?? [guid]::NewGuid().ToString()
            Source       = 'maester'
            Category     = $f.Category ?? 'Identity'
            Title        = $f.Title ?? 'Unknown'
            Severity     = Map-Severity ($f.Severity ?? 'Medium')
            Compliant    = $f.Compliant
            Detail       = $f.Detail ?? ''
            Remediation  = $f.Remediation ?? ''
            ResourceId   = $f.ResourceId ?? ''
            LearnMoreUrl = $f.LearnMoreUrl ?? ''
        })
    }
    Write-Host "  Maester: $($maesterResult.Findings.Count) findings" -ForegroundColor Gray
} else {
    Write-Host "`n[6/7] Skipping Maester (excluded)" -ForegroundColor DarkGray
}

# --- Write output ---
try {
    if (-not (Test-Path $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }
    $outputFile = Join-Path $OutputPath 'results.json'
    $allResults | ConvertTo-Json -Depth 5 | Set-Content -Path $outputFile -Encoding UTF8
} catch {
    Write-Error "Failed to write output to ${OutputPath}: $_"
    return
}

# --- Generate reports ---
$htmlReport = Join-Path $OutputPath 'report.html'
$mdReport   = Join-Path $OutputPath 'report.md'

try {
    & "$PSScriptRoot\New-HtmlReport.ps1" -InputPath $outputFile -OutputPath $htmlReport
} catch {
    Write-Warning "HTML report generation failed: $_"
}

try {
    & "$PSScriptRoot\New-MdReport.ps1" -InputPath $outputFile -OutputPath $mdReport
} catch {
    Write-Warning "Markdown report generation failed: $_"
}

$high = ($allResults | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant }).Count
$medium = ($allResults | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant }).Count
$low = ($allResults | Where-Object { $_.Severity -eq 'Low' -and -not $_.Compliant }).Count

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total findings: $($allResults.Count)"
Write-Host "  Non-compliant — High: $high  Medium: $medium  Low: $low" -ForegroundColor Yellow
Write-Host "  Output: $outputFile" -ForegroundColor Green
