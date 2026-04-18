#Requires -Version 7.4
<#
.SYNOPSIS
    Generate a Markdown report from azure-analyzer results.
.DESCRIPTION
    Reads output/results.json (or a specified file) and writes a Markdown
    report to output/report.md.
    Sections: summary table, per-category findings, and Fix Now / Plan / Track.
.PARAMETER InputPath
    Path to results.json. Defaults to .\output\results.json.
.PARAMETER OutputPath
    Path for report.md. Defaults to .\output\report.md.
#>
[CmdletBinding()]
param (
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.md'),
    [string] $TriagePath,
    [object] $Portfolio
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'modules' 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) {
    . $sanitizePath
}
$frameworkMapperPath = Join-Path $PSScriptRoot 'modules' 'shared' 'FrameworkMapper.ps1'
if (Test-Path $frameworkMapperPath) {
    . $frameworkMapperPath
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$findings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)
if (-not $Portfolio) {
    $portfolioPath = Join-Path (Split-Path $InputPath -Parent) 'portfolio.json'
    if (Test-Path $portfolioPath) {
        try {
            $Portfolio = Get-Content $portfolioPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning (Remove-Credentials "Could not load portfolio data from ${portfolioPath}: $_")
        }
    }
}

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$total = @($findings).Count
$high = @($findings | Where-Object { $_.Severity -eq 'High' }).Count
$medium = @($findings | Where-Object { $_.Severity -eq 'Medium' }).Count
$low = @($findings | Where-Object { $_.Severity -eq 'Low' }).Count
$info = @($findings | Where-Object { $_.Severity -eq 'Info' }).Count
$compliantCount = @($findings | Where-Object { $_.Compliant -eq $true }).Count
$nonCompliantCount = $total - $compliantCount

$lines = [System.Collections.Generic.List[string]]::new()

function Get-PortfolioSlug([string] $text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return 'unknown' }
    return (($text.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-|-$)', '')
}

$lines.Add("# Azure Analyzer Report — $date")
$lines.Add('')
$lines.Add('## Summary')
$lines.Add('')
$lines.Add('| Metric | Count |')
$lines.Add('|---|---|')
$lines.Add("| Total findings | $total |")
$lines.Add("| Non-compliant | $nonCompliantCount |")
$lines.Add("| Compliant | $compliantCount |")
$lines.Add("| High severity | $high |")
$lines.Add("| Medium severity | $medium |")
$lines.Add("| Low severity | $low |")
$lines.Add("| Info | $info |")
$lines.Add('')

$bySource = @($findings | Group-Object -Property Source)
$sourceCountMap = @{}
foreach ($sg in $bySource) { $sourceCountMap[$sg.Name] = $sg }

# Load tool status metadata if available (manifest-driven source list)
$manifestPath = Join-Path $PSScriptRoot 'tools' 'tool-manifest.json'
$allSources   = @()
$sourceLabels = @{}
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        foreach ($t in $manifest.tools) {
            if (-not $t.enabled) { continue }
            $allSources += $t.name
            $sourceLabels[$t.name] = $t.displayName
        }
    } catch {
        Write-Warning "Could not parse tool-manifest.json; falling back to built-in source list. $_"
    }
}
if ($allSources.Count -eq 0) {
    $allSources   = @('azqr','psrule','azgovviz','alz-queries','wara','defender-for-cloud','kubescape','kube-bench','falco','maester','scorecard','ado-connections','identity-correlator','zizmor','gitleaks','trivy')
    $sourceLabels = @{ 'azqr'='Azure Quick Review'; 'psrule'='PSRule'; 'azgovviz'='AzGovViz'; 'alz-queries'='ALZ Queries'; 'wara'='WARA'; 'defender-for-cloud'='Defender for Cloud'; 'kubescape'='Kubescape'; 'kube-bench'='kube-bench'; 'falco'='Falco'; 'maester'='Maester'; 'scorecard'='Scorecard'; 'ado-connections'='ADO Service Connections'; 'identity-correlator'='Identity Correlator'; 'zizmor'='zizmor'; 'gitleaks'='gitleaks'; 'trivy'='Trivy' }
}
$toolStatusMap = @{}
$statusJsonPath = Join-Path (Split-Path $InputPath -Parent) 'tool-status.json'
if (Test-Path $statusJsonPath) {
    try {
        $statusData = @(Get-Content $statusJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop)
        foreach ($ts in $statusData) { $toolStatusMap[$ts.Tool] = $ts.Status }
    } catch { }
}

$lines.Add('### By source')
$lines.Add('')
$lines.Add('| Source | Status | Findings | Non-compliant |')
$lines.Add('|---|---|---|---|')
foreach ($src in $allSources) {
    $label = $sourceLabels[$src]
    $status = if ($toolStatusMap.ContainsKey($src)) { $toolStatusMap[$src] } else { if ($sourceCountMap.ContainsKey($src)) { 'Success' } else { 'Skipped' } }
    if ($sourceCountMap.ContainsKey($src)) {
        $grp = $sourceCountMap[$src]
        $nc = @($grp.Group | Where-Object { -not $_.Compliant }).Count
        $lines.Add("| $label | $status | $($grp.Count) | $nc |")
    } else {
        $lines.Add("| $label | $status | 0 | 0 |")
    }
}
$lines.Add('')

if ($Portfolio -and $Portfolio.PSObject.Properties['Subscriptions']) {
    $portfolioSubs = @($Portfolio.Subscriptions)
    $portfolioCorrelations = if ($Portfolio.PSObject.Properties['Correlations']) { @($Portfolio.Correlations) } else { @() }
    $portfolioMgs = if ($Portfolio.PSObject.Properties['ManagementGroups']) { @($Portfolio.ManagementGroups) } else { @() }

    if (@($portfolioSubs).Count -gt 0) {
        $lines.Add('## Portfolio rollup')
        $lines.Add('')

        $breadcrumbPath = @()
        if (@($portfolioMgs).Count -gt 0 -and $portfolioMgs[0].PSObject.Properties['ManagementGroupPath']) {
            $breadcrumbPath = @($portfolioMgs[0].ManagementGroupPath)
        } elseif ($portfolioSubs[0].PSObject.Properties['ManagementGroupPath']) {
            $breadcrumbPath = @($portfolioSubs[0].ManagementGroupPath)
        }
        if (@($breadcrumbPath).Count -gt 0) {
            $lines.Add("**Management group path:** $($breadcrumbPath -join ' > ')")
            $lines.Add('')
        }

        $lines.Add('| Subscription | Critical | High | Medium | Low | Info | Non-compliant | Monthly cost | Worst |')
        $lines.Add('|---|---:|---:|---:|---:|---:|---:|---|---|')
        foreach ($sub in $portfolioSubs) {
            $subName = if ($sub.SubscriptionName) { [string]$sub.SubscriptionName } else { [string]$sub.SubscriptionId }
            $subLabel = ($subName -replace '\|', '\|')
            $anchor = Get-PortfolioSlug -text ([string]$sub.SubscriptionId)
            $costText = if ($null -ne $sub.MonthlyCost -and [double]$sub.MonthlyCost -gt 0) {
                "{0:N2} {1}" -f [double]$sub.MonthlyCost, ($(if ($sub.Currency) { [string]$sub.Currency } else { 'USD' }))
            } else {
                'n/a'
            }
            $lines.Add("| [$subLabel](#portfolio-sub-$anchor) | $([int]$sub.SeverityCounts.Critical) | $([int]$sub.SeverityCounts.High) | $([int]$sub.SeverityCounts.Medium) | $([int]$sub.SeverityCounts.Low) | $([int]$sub.SeverityCounts.Info) | $([int]$sub.NonCompliantCount) | $costText | $($sub.WorstSeverity) |")
        }
        $lines.Add('')

        $lines.Add('### Cross-subscription identities')
        $lines.Add('')
        if (@($portfolioCorrelations).Count -gt 0) {
            $lines.Add('| Identity | Severity | Subscriptions | Detail |')
            $lines.Add('|---|---|---:|---|')
            foreach ($corr in $portfolioCorrelations) {
                $corrTitle = ([string]$corr.Title -replace '\|', '\|' -replace "`n|`r", ' ')
                $corrDetail = ([string]$corr.Detail -replace '\|', '\|' -replace "`n|`r", ' ')
                $lines.Add("| $corrTitle | $($corr.Severity) | $($corr.EvidenceCount) | $corrDetail |")
            }
        } else {
            $lines.Add('No cross-subscription identity reuse was detected in this run.')
        }
        $lines.Add('')

        foreach ($sub in $portfolioSubs) {
            $subName = if ($sub.SubscriptionName) { [string]$sub.SubscriptionName } else { [string]$sub.SubscriptionId }
            $anchor = Get-PortfolioSlug -text ([string]$sub.SubscriptionId)
            $lines.Add("<a id=`"portfolio-sub-$anchor`"></a>")
            $lines.Add("### Portfolio sub $subName")
            $lines.Add('')
            if ($sub.PSObject.Properties['ManagementGroupPath'] -and @($sub.ManagementGroupPath).Count -gt 0) {
                $lines.Add("- **Management group path:** $(@($sub.ManagementGroupPath) -join ' > ')")
            }
            $lines.Add("- **Worst severity:** $($sub.WorstSeverity)")
            if ($null -ne $sub.MonthlyCost -and [double]$sub.MonthlyCost -gt 0) {
                $lines.Add(("- **Monthly cost:** {0:N2} {1}" -f [double]$sub.MonthlyCost, ($(if ($sub.Currency) { [string]$sub.Currency } else { 'USD' }))))
            }
            if ($sub.PSObject.Properties['SourceCounts'] -and @($sub.SourceCounts).Count -gt 0) {
                $sourceSummary = @($sub.SourceCounts | ForEach-Object { "$($_.Source)=$($_.Count)" }) -join ', '
                $lines.Add("- **By source:** $sourceSummary")
            }
            $lines.Add('')
            $lines.Add('| Top entity | Type | Worst severity | Non-compliant | Monthly cost |')
            $lines.Add('|---|---|---|---:|---:|')
            if ($sub.PSObject.Properties['TopEntities'] -and @($sub.TopEntities).Count -gt 0) {
                foreach ($entity in @($sub.TopEntities)) {
                    $entityName = if ($entity.DisplayName) { [string]$entity.DisplayName } else { [string]$entity.EntityId }
                    $entityName = $entityName -replace '\|', '\|'
                    $lines.Add("| $entityName | $($entity.EntityType) | $($entity.WorstSeverity) | $([int]$entity.NonCompliantCount) | $([double]$entity.MonthlyCost) |")
                }
            } else {
                $lines.Add('| No entities captured |  |  | 0 | 0 |')
            }
            $lines.Add('')
        }
    }
}

# AI Triage section
if ($TriagePath -and (Test-Path $TriagePath)) {
    try {
        $td = @(Get-Content $TriagePath -Raw | ConvertFrom-Json -ErrorAction Stop)
        $te = @($td | Where-Object { $null -ne $_.AiPriority } | Sort-Object AiPriority)
        if ($te.Count -gt 0) {
            $lines.Add('## AI-Assisted Triage')
            $lines.Add('')
            $lines.Add('| # | Finding | Severity | Source | Risk | Remediation |')
            $lines.Add('|---|---|---|---|---|---|')
            foreach ($t in $te) {
                $title = ($t.Title -replace '\|', '\\|')
                $risk = ($t.AiRiskContext -replace '\|', '\\|' -replace "`n|`r", ' ')
                $rem = ($t.AiRemediation -replace '\|', '\\|' -replace "`n|`r", ' ')
                $lines.Add("| $($t.AiPriority) | $title | $($t.Severity) | $($t.Source) | $risk | $rem |")
            }
            $lines.Add('')
        }
    } catch { }
}

# Compliance framework coverage
if (Get-Command Get-FrameworkCoverage -ErrorAction SilentlyContinue) {
    try {
        $coverage = @(Get-FrameworkCoverage -Findings $findings)
        if ($coverage.Count -gt 0) {
            $lines.Add('## Compliance coverage')
            $lines.Add('')
            $lines.Add('| Framework | Version | Controls hit | Total controls | Coverage | Status |')
            $lines.Add('|---|---|---:|---:|---:|---|')
            foreach ($c in $coverage) {
                $icon = switch ($c.Status) { 'green' { '🟢' } 'yellow' { '🟡' } 'red' { '🔴' } default { '⚪' } }
                $lines.Add("| $($c.DisplayName) | $($c.Version) | $($c.ControlsHit) | $($c.ControlsTotal) | $($c.PercentCovered)% | $icon |")
            }
            $lines.Add('')
        }
    } catch { }
}

# Per-category sections
$lines.Add('## Findings by category')
$lines.Add('')
$byCategory = @($findings | Group-Object -Property Category | Sort-Object Name)
foreach ($cat in $byCategory) {
    $lines.Add("### $($cat.Name)")
    $lines.Add('')
    $lines.Add('| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|---|---|')
    foreach ($f in ($cat.Group | Sort-Object Severity, Title)) {
        $compliantStr = if ($f.Compliant) { 'Yes' } else { 'No' }
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $title = ($f.Title -replace '\|', '\\|' -replace "`n|`r", ' ')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Severity) | $($f.Source) | $compliantStr | $detail | $resId | $learnMore |")
    }
    $lines.Add('')
}

# Action sections
$fixNow = @($findings | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant } | Sort-Object Title)
$planFix = @($findings | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant } | Sort-Object Title)
$track = @($findings | Where-Object { ($_.Severity -eq 'Low' -or $_.Severity -eq 'Info') -and -not $_.Compliant } | Sort-Object Title)

$lines.Add('## Action plan')
$lines.Add('')
$lines.Add('### Fix now (High, non-compliant)')
$lines.Add('')
if ($fixNow.Count -eq 0) {
    $lines.Add('No high-severity non-compliant findings.')
} else {
    $lines.Add('| Title | Source | Detail | Remediation | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($f in $fixNow) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $rem = ($f.Remediation -replace '\|', '\\|')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Source) | $detail | $rem | $resId | $learnMore |")
    }
}
$lines.Add('')

$lines.Add('### Plan to fix (Medium, non-compliant)')
$lines.Add('')
if ($planFix.Count -eq 0) {
    $lines.Add('No medium-severity non-compliant findings.')
} else {
    $lines.Add('| Title | Source | Detail | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($f in $planFix) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Source) | $detail | $resId | $learnMore |")
    }
}
$lines.Add('')

$lines.Add('### Track (Low/Info, non-compliant)')
$lines.Add('')
if ($track.Count -eq 0) {
    $lines.Add('No low/info non-compliant findings.')
} else {
    $lines.Add('| Title | Severity | Source | Detail | Resource ID | Learn More |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($f in $track) {
        $title = ($f.Title -replace '\|', '\\|')
        $detail = ($f.Detail -replace '\|', '\\|' -replace "`n|`r", ' ')
        $resId = ($f.ResourceId -replace '\|', '\\|')
        $learnMore = if ([string]::IsNullOrWhiteSpace($f.LearnMoreUrl)) { '' } else { "[$($f.LearnMoreUrl)]($($f.LearnMoreUrl))" }
        $lines.Add("| $title | $($f.Severity) | $($f.Source) | $detail | $resId | $learnMore |")
    }
}
$lines.Add('')

try {
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }
    $output = Remove-Credentials ($lines -join "`n")
    $output | Set-Content -Path $OutputPath -Encoding UTF8 -NoNewline
} catch {
    Write-Error (Remove-Credentials "Failed to write Markdown report to ${OutputPath}: $_")
    return
}
Write-Host "Markdown report written to: $OutputPath" -ForegroundColor Green
