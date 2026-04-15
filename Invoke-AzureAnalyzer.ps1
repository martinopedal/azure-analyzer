#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Analyzer ÔÇö unified Azure assessment orchestrator.
.DESCRIPTION
    Calls all seven assessment tool wrappers (azqr, PSRule, AzGovViz, alz-queries,
    WARA, Maester, Scorecard), merges results into a unified schema, and writes
    output/results.json.
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
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),
    [string[]] $IncludeTools,
    [string[]] $ExcludeTools,
    [switch] $SkipPrereqCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Tool selection ---
$validTools = @('azqr', 'psrule', 'azgovviz', 'alz-queries', 'wara', 'maester', 'scorecard')
$azureScopedTools = @('azqr', 'psrule', 'azgovviz', 'alz-queries', 'wara')

if ($IncludeTools -and $ExcludeTools) {
    throw "Cannot use both -IncludeTools and -ExcludeTools. Use one or the other."
}
foreach ($t in @($IncludeTools) + @($ExcludeTools) | Where-Object { $_ }) {
    if ($t -notin $validTools) { throw "Unknown tool '$t'. Valid: $($validTools -join ', ')" }
}

function ShouldRunTool { param ([string]$ToolName)
    if ($IncludeTools) { return $ToolName -in $IncludeTools }
    if ($ExcludeTools) { return $ToolName -notin $ExcludeTools }
    return $true
}

$needsAzureScope = $azureScopedTools | Where-Object { ShouldRunTool $_ }
if ($needsAzureScope -and -not $SubscriptionId -and -not $ManagementGroupId) {
    throw "At least one of -SubscriptionId or -ManagementGroupId is required for: $($needsAzureScope -join ', ')."
}

# --- Prerequisite auto-install ---
function Install-Prerequisites {
    Write-Host "`n[0/7] Checking prerequisites..." -ForegroundColor Yellow
    $psModules = @(
        @{ Name = 'Az.ResourceGraph'; Tool = 'alz-queries' },
        @{ Name = 'PSRule'; Tool = 'psrule' },
        @{ Name = 'PSRule.Rules.Azure'; Tool = 'psrule' },
        @{ Name = 'WARA'; Tool = 'wara' },
        @{ Name = 'Maester'; Tool = 'maester' }
    )
    foreach ($mod in $psModules) {
        if (-not (ShouldRunTool $mod.Tool)) { continue }
        if (-not (Get-Module -ListAvailable -Name $mod.Name -ErrorAction SilentlyContinue)) {
            Write-Host "  Installing $($mod.Name)..." -ForegroundColor Yellow
            try {
                Install-Module $mod.Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Write-Host "  ✓ $($mod.Name) installed" -ForegroundColor Green
            } catch {
                Write-Warning "Could not install $($mod.Name): $_. $($mod.Tool) may be skipped."
            }
        }
    }
    $cliTools = @(
        @{ Cmd = 'azqr'; Tool = 'azqr'; Name = 'Azure Quick Review'; Install = 'winget install azure-quick-review.azqr' },
        @{ Cmd = 'scorecard'; Tool = 'scorecard'; Name = 'OpenSSF Scorecard'; Install = 'Download from https://github.com/ossf/scorecard/releases' }
    )
    foreach ($cli in $cliTools) {
        if (-not (ShouldRunTool $cli.Tool)) { continue }
        if (-not (Get-Command $cli.Cmd -ErrorAction SilentlyContinue)) {
            Write-Host "  ⚠ $($cli.Name) not found. Install: $($cli.Install)" -ForegroundColor DarkYellow
        }
    }
}

if (-not $SkipPrereqCheck) { Install-Prerequisites }


$modulesPath = Join-Path $PSScriptRoot 'modules'
$toolErrors = [System.Collections.Generic.List[PSCustomObject]]::new()

function Invoke-Wrapper {
    param ([string]$Script, [hashtable]$Params, [int]$MaxRetries = 2, [int]$RetryDelaySec = 5)
    $scriptPath = Join-Path $modulesPath $Script
    if (-not (Test-Path $scriptPath)) {
        Write-Warning "$Script not found at $scriptPath"
        return [PSCustomObject]@{ Source = $Script; Findings = @() }
    }
    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        try {
            $result = & $scriptPath @Params
            if ($result.Findings.Count -gt 0 -or $attempt -gt $MaxRetries) { return $result }
            Write-Warning "$Script returned 0 findings (attempt $attempt/$($MaxRetries+1)), retrying..."
            Start-Sleep -Seconds $RetryDelaySec
        } catch {
            if ($attempt -le $MaxRetries) {
                Write-Warning "$Script failed (attempt $attempt/$($MaxRetries+1)): $_ — retrying in ${RetryDelaySec}s..."
                Start-Sleep -Seconds $RetryDelaySec
            } else {
                Write-Warning "$Script failed after $($MaxRetries+1) attempts: $_"
                $toolErrors.Add([PSCustomObject]@{ Tool = $Script; Error = $_.Exception.Message; Timestamp = Get-Date })
                return [PSCustomObject]@{ Source = $Script; Findings = @() }
            }
        }
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

function Get-SeverityRank ([string]$Sev) {
    switch ($Sev) { 'High' { 3 } 'Medium' { 2 } 'Low' { 1 } default { 0 } }
}

function Remove-DuplicateFindings {
    param ([System.Collections.Generic.List[PSCustomObject]]$Findings)
    $deduped = [System.Collections.Generic.List[PSCustomObject]]::new()
    $groups = $Findings | Group-Object { "$($_.ResourceId)`t$($_.Title)".ToLowerInvariant() }
    foreach ($g in $groups) {
        if ($g.Count -eq 1) { $deduped.Add($g.Group[0]); continue }
        $best = $g.Group | Sort-Object { Get-SeverityRank $_.Severity } -Descending | Select-Object -First 1
        $mergedSource = ($g.Group | Select-Object -ExpandProperty Source -Unique | Sort-Object) -join ', '
        $longestDetail = ($g.Group | Sort-Object { ($_.Detail ?? '').Length } -Descending | Select-Object -First 1).Detail
        $merged = $best.PSObject.Copy()
        $merged.Source = $mergedSource
        $merged.Detail = $longestDetail
        $deduped.Add($merged)
    }
    return $deduped
}

Write-Host "=== Azure Analyzer ===" -ForegroundColor Cyan

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- azqr ---
if (ShouldRunTool 'azqr') {
if ($SubscriptionId) {
    Write-Host "`n[1/7] Running azqr..." -ForegroundColor Yellow
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
} else {
    Write-Host "`n[1/7] Skipping azqr (excluded)" -ForegroundColor DarkGray
}

# --- PSRule ---
if (ShouldRunTool 'psrule') {
Write-Host "`n[2/7] Running PSRule..." -ForegroundColor Yellow
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
} else {
    Write-Host "`n[2/7] Skipping psrule (excluded)" -ForegroundColor DarkGray
}

# --- AzGovViz ---
if (ShouldRunTool 'azgovviz') {
if ($ManagementGroupId) {
    Write-Host "`n[3/7] Running AzGovViz..." -ForegroundColor Yellow
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
    Write-Host "`n[3/7] Skipping AzGovViz (no ManagementGroupId provided)" -ForegroundColor DarkGray
}
} else {
    Write-Host "`n[3/7] Skipping azgovviz (excluded)" -ForegroundColor DarkGray
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
    Write-Host "`n[4/7] Skipping alz-queries (excluded)" -ForegroundColor DarkGray
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
    Write-Host "`n[5/7] Skipping wara (excluded)" -ForegroundColor DarkGray
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
    Write-Host "`n[6/7] Skipping maester (excluded)" -ForegroundColor DarkGray
}


# --- Deduplicate cross-tool findings ---
$preDedup = $allResults.Count
$allResults = Remove-DuplicateFindings $allResults
$dedupRemoved = $preDedup - $allResults.Count
if ($dedupRemoved -gt 0) {
    Write-Host "  Deduplication: removed $dedupRemoved duplicate(s) ($preDedup -> $($allResults.Count))" -ForegroundColor Gray
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

# --- AI triage (optional) ---
$triageFile = Join-Path $OutputPath 'triage.json'
if ($EnableAiTriage) {
    Write-Host "`n[AI] Running Copilot triage..." -ForegroundColor Magenta
    try {
        $triageResult = & (Join-Path $modulesPath 'Invoke-CopilotTriage.ps1') `
            -InputPath $outputFile -OutputPath $triageFile
        if ($null -eq $triageResult) { Write-Warning "AI triage did not produce results." }
    } catch { Write-Warning "AI triage failed: $_ — continuing without enrichment." }
} else {
    if (Test-Path $triageFile) { Remove-Item $triageFile -Force -ErrorAction SilentlyContinue }
}
$triageArg = if (Test-Path $triageFile) { @{ TriagePath = $triageFile } } else { @{} }

# --- Generate reports ---
$htmlReport = Join-Path $OutputPath 'report.html'
$mdReport   = Join-Path $OutputPath 'report.md'

try {
    & "$PSScriptRoot\New-HtmlReport.ps1" -InputPath $outputFile -OutputPath $htmlReport @triageArg
} catch {
    Write-Warning "HTML report generation failed: $_"
}

try {
    & "$PSScriptRoot\New-MdReport.ps1" -InputPath $outputFile -OutputPath $mdReport @triageArg
} catch {
    Write-Warning "Markdown report generation failed: $_"
}

$high = ($allResults | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant }).Count
$medium = ($allResults | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant }).Count
$low = ($allResults | Where-Object { $_.Severity -eq 'Low' -and -not $_.Compliant }).Count

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total findings: $($allResults.Count)"
Write-Host "  Non-compliant ÔÇö High: $high  Medium: $medium  Low: $low" -ForegroundColor Yellow
Write-Host "  Output: $outputFile" -ForegroundColor Green

# --- Error summary ---
if ($toolErrors.Count -gt 0) {
    $errorsFile = Join-Path $OutputPath 'errors.json'
    try {
        $toolErrors | ConvertTo-Json -Depth 3 | Set-Content -Path $errorsFile -Encoding UTF8
    } catch {
        Write-Warning "Failed to write errors.json: $_"
    }
    Write-Host "`n⚠️ $($toolErrors.Count) tool(s) encountered errors:" -ForegroundColor Red
    foreach ($te in $toolErrors) {
        Write-Host "  - $($te.Tool): $($te.Error)" -ForegroundColor Red
    }
}