#Requires -Version 7.4
<#
.SYNOPSIS
    Generate an offline HTML report from azure-analyzer results.
.DESCRIPTION
    Reads output/results.json and writes a single self-contained HTML file
    to output/report.html. No CDN dependencies. All CSS is inline.
.PARAMETER InputPath
    Path to results.json. Defaults to .\output\results.json.
.PARAMETER OutputPath
    Path for report.html. Defaults to .\output\report.html.
.PARAMETER Trend
    Optional array of run-trend objects from Get-RunTrend. When provided, an inline
    SVG sparkline is rendered alongside the delta banner showing NonCompliant counts
    across the last N runs (oldest left, newest right). Omit to suppress the sparkline.
#>
[CmdletBinding()]
param (
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.html'),
    [string] $TriagePath = '',
    [string] $PreviousRun = '',
    [object] $Portfolio,
    [object[]] $Trend = @()
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
$reportDeltaPath = Join-Path $PSScriptRoot 'modules' 'shared' 'ReportDelta.ps1'
if (Test-Path $reportDeltaPath) {
    . $reportDeltaPath
}
$execDashRenderPath = Join-Path $PSScriptRoot 'modules' 'shared' 'ExecDashboardRender.ps1'
if (Test-Path $execDashRenderPath) {
    . $execDashRenderPath
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

# --- Entities (issue #209) -- graceful degrade if entities.json missing ---
$entities = @()
$entitiesPath = Join-Path (Split-Path $InputPath -Parent) 'entities.json'
$entityStorePath = Join-Path $PSScriptRoot 'modules' 'shared' 'EntityStore.ps1'
if ((Test-Path $entitiesPath) -and (Test-Path $entityStorePath)) {
    try {
        if (-not (Get-Command Import-EntitiesFile -ErrorAction SilentlyContinue)) {
            . $entityStorePath
        }
        $entityFile = Import-EntitiesFile -Path $entitiesPath
        $entities = @($entityFile.Entities)
    } catch {
        Write-Warning (Remove-Credentials "Could not load entities from ${entitiesPath}: $_")
    }
}

# --- Run-mode metadata (incremental / scheduled -- issue #94) ---
$runMetadata = $null
$runMetadataPath = Join-Path (Split-Path $InputPath -Parent) 'run-metadata.json'
if (Test-Path $runMetadataPath) {
    try { $runMetadata = Get-Content $runMetadataPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Warning (Remove-Credentials "Failed to read run-metadata.json: $_") }
}

# --- Report v2 delta vs previous run ---
$deltaStatus  = @{}
$deltaSummary = $null
$resolvedRows = @()
if ($PreviousRun -and (Test-Path $PreviousRun) -and (Get-Command Get-ReportDelta -ErrorAction SilentlyContinue)) {
    try {
        $prev = @(Get-Content $PreviousRun -Raw | ConvertFrom-Json -ErrorAction Stop)
        $delta = Get-ReportDelta -Current $findings -Previous $prev
        $deltaStatus  = $delta.Status
        $deltaSummary = $delta.Summary
        $resolvedRows = @($delta.Resolved)
        # Fold resolved synthetic rows so they render with status=Resolved badges.
        if ($resolvedRows.Count -gt 0) {
            foreach ($r in $resolvedRows) {
                $r | Add-Member -NotePropertyName Compliant -NotePropertyValue $true -Force
            }
            $findings = @($findings + $resolvedRows)
        }
    } catch {
        Write-Warning (Remove-Credentials "Report delta computation failed: $_")
    }
}

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'
$total = @($findings).Count
$high = @($findings | Where-Object { $_.Severity -eq 'High' -and -not $_.Compliant }).Count
$critical = @($findings | Where-Object { $_.Severity -eq 'Critical' -and -not $_.Compliant }).Count
$medium = @($findings | Where-Object { $_.Severity -eq 'Medium' -and -not $_.Compliant }).Count
$low = @($findings | Where-Object { $_.Severity -eq 'Low' -and -not $_.Compliant }).Count
$compliantCount = @($findings | Where-Object { $_.Compliant -eq $true }).Count
$compliantPct = if ($total -gt 0) { [math]::Round(($compliantCount / $total) * 100) } else { 0 }

function HE([string]$s) {
    $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

function SeverityClass([string]$s) {
    switch ($s) {
        'Critical' { return 'sev-critical' }
        'High'   { return 'sev-high' }
        'Medium' { return 'sev-medium' }
        'Low'    { return 'sev-low' }
        default  { return 'sev-info' }
    }
}

function Get-CanonicalFrameworkName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $trimmed = $Name.Trim()
    switch -Regex ($trimmed) {
        '^(?i)cis(\s+azure.*)?$' { return 'CIS Azure' }
        '^(?i)nist(\s*800[-\s]?53.*)?$' { return 'NIST 800-53' }
        '^(?i)(azure\s+)?waf(\s+.*)?$' { return 'Azure WAF' }
        '^(?i)(azure\s+)?caf(\s+.*)?$' { return 'Azure CAF' }
        '^(?i)soc[\s-]*2.*$' { return 'SOC2' }
        '^(?i)pci(\s*[-\s]?dss.*)?$' { return 'PCI-DSS' }
        default { return $trimmed }
    }
}

function Get-FindingFrameworkNames($Finding) {
    $frameworks = New-Object System.Collections.Generic.List[string]

    if ($Finding.PSObject.Properties.Match('Frameworks').Count -gt 0 -and $Finding.Frameworks) {
        foreach ($fw in @($Finding.Frameworks)) {
            $raw = if ($fw -is [string]) { $fw } elseif ($fw.PSObject.Properties.Match('Name').Count -gt 0) { [string]$fw.Name } elseif ($fw.PSObject.Properties.Match('framework').Count -gt 0) { [string]$fw.framework } else { [string]$fw }
            $normalized = Get-CanonicalFrameworkName $raw
            if (-not [string]::IsNullOrWhiteSpace($normalized)) { $frameworks.Add($normalized) }
        }
    }
    if ($Finding.PSObject.Properties.Match('Controls').Count -gt 0 -and $Finding.Controls) {
        foreach ($ctrl in @($Finding.Controls)) {
            $normalized = Get-CanonicalFrameworkName ([string]$ctrl)
            if ($normalized -in @('CIS Azure', 'NIST 800-53', 'Azure WAF', 'Azure CAF', 'SOC2', 'PCI-DSS')) {
                $frameworks.Add($normalized)
            }
        }
    }

    return @($frameworks | Select-Object -Unique)
}

function Get-AnchorId([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return 'portfolio-sub-unknown' }
    return ('portfolio-sub-' + (($text.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-|-$)', ''))
}

function Get-HeatClass([string]$Severity, [int]$Count) {
    if ($Count -le 0) { return 'heat-zero' }
    switch ($Severity) {
        'Critical' { return 'heat-critical' }
        'High'     { return 'heat-high' }
        'Medium'   { return 'heat-medium' }
        'Low'      { return 'heat-low' }
        default    { return 'heat-info' }
    }
}

function Get-FindingResourceGroup($Finding) {
    # Prefer explicit ResourceGroup property; fall back to parsing the ARM ResourceId.
    $explicit = $null
    try { $explicit = $Finding.ResourceGroup } catch { $explicit = $null }
    if (-not [string]::IsNullOrWhiteSpace([string]$explicit)) { return [string]$explicit }
    $rid = $null
    try { $rid = [string]$Finding.ResourceId } catch { $rid = $null }
    if ([string]::IsNullOrWhiteSpace($rid)) { return '' }
    if ($rid -match '/resourceGroups/([^/]+)') { return $Matches[1] }
    if ($rid -match '/resourcegroups/([^/]+)') { return $Matches[1] }
    return ''
}

# --- Load triage data if available ---
$triageFindings = @()
$hasTriage = $false
if ($TriagePath -and (Test-Path $TriagePath)) {
    try {
        $triageFindings = @(Get-Content $TriagePath -Raw | ConvertFrom-Json -ErrorAction Stop)
        $triageFindings = @($triageFindings | Where-Object { $null -ne $_.AiPriority } | Sort-Object AiPriority)
        if ($triageFindings.Count -gt 0) { $hasTriage = $true }
    } catch {
        Write-Warning "Could not load triage data from ${TriagePath}: $_"
    }
}

# --- Per-source breakdown data (manifest-driven) ---
$manifestPath = Join-Path $PSScriptRoot 'tools' 'tool-manifest.json'
$allSources   = @()
$sourceLabels = @{}
$sourceColors = @{}
$frameworkPriority = @('CIS Azure', 'NIST 800-53', 'Azure WAF', 'Azure CAF', 'SOC2', 'PCI-DSS')
$sourceFrameworks = @{}
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        foreach ($t in $manifest.tools) {
            $mappedFrameworks = @()
            if ($t.PSObject.Properties['frameworks'] -and $t.frameworks) {
                $mappedFrameworks = @($t.frameworks | ForEach-Object { Get-CanonicalFrameworkName ([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            }
            $sourceFrameworks[$t.name] = $mappedFrameworks
            if (-not $t.enabled) { continue }
            $allSources += $t.name
            $sourceLabels[$t.name] = $t.displayName
            if ($t.PSObject.Properties['report'] -and $t.report.PSObject.Properties['color']) {
                $sourceColors[$t.name] = [string]$t.report.color
            } else {
                $sourceColors[$t.name] = '#546e7a'
            }
        }
    } catch {
        Write-Warning "Could not parse tool-manifest.json; falling back to built-in source list. $_"
    }
}
# Safety net: if manifest is missing, keep the legacy hardcoded set so a
# report can still be generated in degraded environments.
if ($allSources.Count -eq 0) {
    $allSources   = @('azqr','psrule','azgovviz','alz-queries','wara','defender-for-cloud','kubescape','kube-bench','falco','maester','scorecard','ado-connections','ado-pipelines','identity-correlator','zizmor','gitleaks','trivy','azure-cost','finops','bicep-iac','terraform-iac','sentinel-incidents','sentinel-coverage')
    $sourceLabels = @{ 'azqr'='Azure Quick Review'; 'psrule'='PSRule'; 'azgovviz'='AzGovViz'; 'alz-queries'='ALZ Queries'; 'wara'='WARA'; 'defender-for-cloud'='Defender for Cloud'; 'kubescape'='Kubescape'; 'kube-bench'='kube-bench'; 'falco'='Falco'; 'maester'='Maester'; 'scorecard'='Scorecard'; 'ado-connections'='ADO Service Connections'; 'ado-pipelines'='ADO Pipeline Security'; 'identity-correlator'='Identity Correlator'; 'zizmor'='zizmor'; 'gitleaks'='gitleaks'; 'trivy'='Trivy'; 'azure-cost'='Azure Cost'; 'finops'='FinOps Signals'; 'bicep-iac'='Bicep IaC Validation'; 'terraform-iac'='Terraform IaC Validation'; 'sentinel-incidents'='Microsoft Sentinel'; 'sentinel-coverage'='Sentinel Coverage' }
    $sourceColors = @{ 'azqr'='#1565c0'; 'psrule'='#6a1b9a'; 'azgovviz'='#00838f'; 'alz-queries'='#e65100'; 'wara'='#2e7d32'; 'defender-for-cloud'='#0078d4'; 'kubescape'='#7b1fa2'; 'kube-bench'='#5e35b1'; 'falco'='#ef6c00'; 'maester'='#7b1fa2'; 'scorecard'='#ff6f00'; 'ado-connections'='#0277bd'; 'ado-pipelines'='#006064'; 'identity-correlator'='#ad1457'; 'zizmor'='#4527a0'; 'gitleaks'='#c62828'; 'trivy'='#00695c'; 'azure-cost'='#388e3c'; 'finops'='#00897b'; 'bicep-iac'='#0d47a1'; 'terraform-iac'='#5c4ee5'; 'sentinel-incidents'='#0078d4'; 'sentinel-coverage'='#3949ab' }
    foreach ($src in $allSources) { $sourceFrameworks[$src] = @() }
}
$sourceGroups = @($findings | Group-Object -Property Source)
$sourceCountMap = @{}
foreach ($sg in $sourceGroups) { $sourceCountMap[$sg.Name] = $sg.Count }
$maxSourceCount = if ($sourceGroups.Count -gt 0) { ($sourceGroups | Measure-Object -Property Count -Maximum).Maximum } else { 1 }
if ($maxSourceCount -eq 0) { $maxSourceCount = 1 }

# Load tool status metadata if available (written by orchestrator)
$toolStatusMap = @{}
$statusJsonPath = Join-Path (Split-Path $InputPath -Parent) 'tool-status.json'
if (Test-Path $statusJsonPath) {
    try {
        $statusData = @(Get-Content $statusJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop)
        foreach ($ts in $statusData) { $toolStatusMap[$ts.Tool] = $ts.Status }
    } catch {
        Write-Warning "Could not load tool status: $_"
    }
}

$sourcesWithResults = @($sourceGroups | ForEach-Object { $_.Name })
$sourcesSkipped = @($allSources | Where-Object { $_ -notin $sourcesWithResults })

# --- Linkify helper: wrap URLs in anchor tags ---
function Get-ControlBadgeClass([string]$control) {
    if ([string]::IsNullOrWhiteSpace($control)) { return 'cb-other' }
    $upper = $control.ToUpperInvariant().TrimStart()
    if ($upper.StartsWith('CIS'))  { return 'cb-cis' }
    if ($upper.StartsWith('NIST')) { return 'cb-nist' }
    if ($upper.StartsWith('PCI'))  { return 'cb-pci' }
    if ($upper.StartsWith('ISO'))  { return 'cb-iso' }
    if ($upper.StartsWith('SOC'))  { return 'cb-soc' }
    if ($upper.StartsWith('HIPAA')){ return 'cb-hipaa' }
    return 'cb-other'
}

function Get-ControlBadgesHtml($finding) {
    $items = @()
    if ($finding.PSObject.Properties.Match('Controls').Count -gt 0 -and $finding.Controls) {
        foreach ($c in @($finding.Controls)) {
            $s = [string]$c
            if (-not [string]::IsNullOrWhiteSpace($s)) { $items += $s.Trim() }
        }
    }
    if ($items.Count -eq 0 -and $finding.PSObject.Properties.Match('Frameworks').Count -gt 0 -and $finding.Frameworks) {
        foreach ($fw in @($finding.Frameworks)) {
            $s = if ($fw -is [string]) { $fw } elseif ($fw.PSObject.Properties.Match('Name').Count -gt 0) { [string]$fw.Name } else { [string]$fw }
            if (-not [string]::IsNullOrWhiteSpace($s)) { $items += $s.Trim() }
        }
    }
    if ($items.Count -eq 0) { return '' }
    $items = $items | Select-Object -Unique
    $chips = foreach ($it in $items) {
        $cls = Get-ControlBadgeClass $it
        "<span class='control-badge $cls' title='$(HE $it)'>$(HE $it)</span>"
    }
    " <span class='control-badges'>" + ($chips -join '') + "</span>"
}

function Linkify([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return HE $text }
    $escaped = HE $text
    $escaped -replace '(https?://[^\s&lt;&quot;]+)', '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>'
}

$rowsJson = ($findings | ForEach-Object {
    @"
{
  id: `"$(HE $_.Id)`",
  source: `"$(HE $_.Source)`",
  category: `"$(HE $_.Category)`",
  title: `"$(HE $_.Title)`",
  severity: `"$(HE $_.Severity)`",
  compliant: $($_.Compliant.ToString().ToLower()),
  detail: `"$(HE $_.Detail)`",
  remediation: `"$(HE $_.Remediation)`",
  resourceId: `"$(HE $_.ResourceId)`",
  learnMoreUrl: `"$(HE $_.LearnMoreUrl)`",
  platform: `"$(HE $_.Platform)`",
  controls: [$((@($_.Controls) | Where-Object { $_ } | ForEach-Object { "`"$(HE ([string]$_))`"" }) -join ',')],
  frameworks: [$((@($_.Frameworks) | Where-Object { $_ } | ForEach-Object { $name = if ($_ -is [string]) { $_ } elseif ($_.PSObject.Properties.Match('Name').Count -gt 0) { [string]$_.Name } else { [string]$_ }; "`"$(HE $name)`"" }) -join ',')]
}
"@
}) -join ','

$byCategory = @($findings | Group-Object -Property Category | Sort-Object Name)
$severityOrder = @('Critical', 'High', 'Medium', 'Low', 'Info')

function New-SeverityCountMap {
    [ordered]@{
        Critical = 0
        High     = 0
        Medium   = 0
        Low      = 0
        Info     = 0
    }
}

function Add-SeverityToCountMap {
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary] $Map,
        [Parameter(Mandatory)][string] $Severity
    )
    switch -Regex ($Severity) {
        '^(?i)critical$' { $Map['Critical']++; break }
        '^(?i)high$'     { $Map['High']++; break }
        '^(?i)medium$'   { $Map['Medium']++; break }
        '^(?i)low$'      { $Map['Low']++; break }
        default          { $Map['Info']++; break }
    }
}

function Get-SeverityDotsHtml {
    param ([Parameter(Mandatory)][System.Collections.IDictionary] $Counts)
    $dots = foreach ($sev in $severityOrder) {
        $val = [int]$Counts[$sev]
        $cls = "tree-dot-$($sev.ToLowerInvariant())"
        "<span class='tree-dot $cls' title='$(HE $sev): $val' aria-label='$(HE $sev): $val'>$val</span>"
    }
    "<span class='tree-dots'>$($dots -join '')</span>"
}

function Get-FindingRuleKey {
    param ([Parameter(Mandatory)]$Finding)

    $ruleId = ''
    foreach ($candidate in @('RuleId', 'Rule', 'ControlId')) {
        if ($Finding.PSObject.Properties.Match($candidate).Count -gt 0) {
            $raw = [string]$Finding.$candidate
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $ruleId = $raw.Trim()
                break
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ruleId)) { return $ruleId }

    $title = ([string]$Finding.Title).Trim()
    if ($title -match '^([A-Za-z][A-Za-z0-9._-]{2,})\s*[:\-]\s+') { return $Matches[1] }
    if ($title -match '^([A-Za-z]{2,}[._-][A-Za-z0-9._-]+)\b') { return $Matches[1] }
    if (-not [string]::IsNullOrWhiteSpace($title)) { return "title:$title" }
    return "finding:$([string]$Finding.Id)"
}

$treeSeverityCounts = New-SeverityCountMap
foreach ($f in $findings) { Add-SeverityToCountMap -Map $treeSeverityCounts -Severity ([string]$f.Severity) }
$severityStripBadges = foreach ($sev in $severityOrder) {
    $count = [int]$treeSeverityCounts[$sev]
    $sevClass = "severity-pill-$($sev.ToLowerInvariant())"
    "<button type='button' class='severity-pill $sevClass' data-severity='$(HE $sev)' aria-pressed='false' onclick=`"filterBySeverityStrip(this,'$(HE $sev)')`">$(HE $sev): $count</button>"
}

$toolGroups = @($findings | Group-Object -Property Source | Sort-Object Name)
$findingsTreeHtml = foreach ($tool in $toolGroups) {
    $toolCounts = New-SeverityCountMap
    foreach ($f in $tool.Group) { Add-SeverityToCountMap -Map $toolCounts -Severity ([string]$f.Severity) }
    $toolPath = "tool::$($tool.Name)"
    $categoryGroups = @($tool.Group | Group-Object -Property Category | Sort-Object Name)
    $toolChildrenHtml = foreach ($category in $categoryGroups) {
        $categoryCounts = New-SeverityCountMap
        foreach ($f in $category.Group) { Add-SeverityToCountMap -Map $categoryCounts -Severity ([string]$f.Severity) }
        $categoryName = if ([string]::IsNullOrWhiteSpace([string]$category.Name)) { 'Uncategorized' } else { [string]$category.Name }
        $categoryPath = "$toolPath|category::$categoryName"
        $ruleGroups = @($category.Group | Group-Object -Property { Get-FindingRuleKey $_ } | Sort-Object Name)
        $categoryChildrenHtml = foreach ($rule in $ruleGroups) {
            $ruleCounts = New-SeverityCountMap
            foreach ($f in $rule.Group) { Add-SeverityToCountMap -Map $ruleCounts -Severity ([string]$f.Severity) }
            $ruleName = if ([string]::IsNullOrWhiteSpace([string]$rule.Name)) { 'Unspecified rule' } else { [string]$rule.Name }
            $rulePath = "$categoryPath|rule::$ruleName"
            $findingItemsHtml = foreach ($f in ($rule.Group | Sort-Object Severity, Title)) {
                $sevClass = SeverityClass $f.Severity
                $compliantBool = if ($f.Compliant) { 'true' } else { 'false' }
                $resourceGroup = HE (Get-FindingResourceGroup $f)
                $frameworkList = @((Get-FindingFrameworkNames $f) | ForEach-Object { [string]$_ })
                $frameworkAttr = HE (($frameworkList -join '|').ToLowerInvariant())
                $resourceId = HE ([string]$f.ResourceId)
                $detail = HE ([string]$f.Detail)
                $remediationHtml = Linkify ([string]$f.Remediation)
                $controlBadgesHtml = Get-ControlBadgesHtml $f
                $learnMoreHtml = if ([string]::IsNullOrWhiteSpace([string]$f.LearnMoreUrl)) { '' } else { "<a href=`"$(HE ([string]$f.LearnMoreUrl))`" target=`"_blank`" rel=`"noopener noreferrer`">Fix it</a>" }
                $rowStatus = ''
                $statusBadge = ''
                if ($deltaSummary) {
                    $k = Get-ReportDeltaKey -Row $f
                    if ($deltaStatus.ContainsKey($k)) { $rowStatus = $deltaStatus[$k] }
                    switch ($rowStatus) {
                        'New'       { $statusBadge = ' <span class="badge badge-new">New</span>' }
                        'Resolved'  { $statusBadge = ' <span class="badge badge-resolved">Resolved</span>' }
                        'Unchanged' { $statusBadge = ' <span class="badge badge-unchanged">Unchanged</span>' }
                    }
                }
                @"
<article class="tree-finding" data-tree-finding="true" data-tree-path="$(HE "$rulePath|finding::$([string]$f.Id)")" data-severity="$(HE ([string]$f.Severity))" data-compliant="$compliantBool" data-source="$(HE ([string]$f.Source))" data-platform="$(HE ([string]$f.Platform))" data-status="$(HE $rowStatus)" data-resourcegroup="$resourceGroup" data-frameworks="$frameworkAttr">
  <header class="tree-finding-header">
    <span class="badge $sevClass">$(HE ([string]$f.Severity))</span>
    <strong class="tree-finding-title">$(HE ([string]$f.Title))</strong>$statusBadge$controlBadgesHtml
  </header>
  <div class="tree-finding-meta"><span class="tree-label">Resource:</span> <span class="resource-id">$resourceId</span></div>
  <div class="tree-finding-meta"><span class="tree-label">Description:</span> $detail</div>
  <div class="tree-finding-meta"><span class="tree-label">Fix:</span> $remediationHtml $(if ($learnMoreHtml) { "&middot; $learnMoreHtml" } else { '' })</div>
</article>
"@
            }
            @"
<details class="tree-node tree-node-rule" data-tree-level="rule" data-tree-path="$(HE $rulePath)">
  <summary><span class="tree-name">$(HE $ruleName)</span> <span class="tree-count">($($rule.Group.Count) findings)</span> $(Get-SeverityDotsHtml -Counts $ruleCounts)</summary>
  <div class="tree-children">
$($findingItemsHtml -join "`n")
  </div>
</details>
"@
        }
        @"
<details class="tree-node tree-node-category" data-tree-level="category" data-tree-path="$(HE $categoryPath)">
  <summary><span class="tree-name">$(HE $categoryName)</span> <span class="tree-count">($($ruleGroups.Count) rules)</span> $(Get-SeverityDotsHtml -Counts $categoryCounts)</summary>
  <div class="tree-children">
$($categoryChildrenHtml -join "`n")
  </div>
</details>
"@
    }
    @"
<details class="tree-node tree-node-tool" data-tree-level="tool" data-tree-path="$(HE $toolPath)" open>
  <summary><span class="tree-name">$(HE ([string]$tool.Name))</span> <span class="tree-count">($($categoryGroups.Count) categories)</span> $(Get-SeverityDotsHtml -Counts $toolCounts)</summary>
  <div class="tree-children">
$($toolChildrenHtml -join "`n")
  </div>
</details>
"@
}

# --- Per-source horizontal bars ---
$sourceBarHtml = foreach ($src in $allSources) {
    $cnt = if ($sourceCountMap.ContainsKey($src)) { $sourceCountMap[$src] } else { 0 }
    $label = $sourceLabels[$src]
    $color = $sourceColors[$src]
    $widthPct = if ($cnt -gt 0) { [math]::Round(($cnt / $maxSourceCount) * 100) } else { 0 }
    @"
<div class="bar-row">
  <span class="bar-label">$label</span>
  <div class="bar-track">
    <div class="bar-fill" style="width:${widthPct}%;background:$color;"></div>
  </div>
  <span class="bar-count">$cnt</span>
</div>
"@
}

# --- Tool coverage summary (status-aware) ---
$toolCoverageHtml = foreach ($src in $allSources) {
    $label = $sourceLabels[$src]
    $status = if ($toolStatusMap.ContainsKey($src)) { $toolStatusMap[$src] } else { $null }
    if ($status -eq 'Success' -or ($null -eq $status -and $src -in $sourcesWithResults)) {
        "<span class='tool-badge tool-active' title='Ran successfully'>&#x2705; $label</span>"
    } elseif ($status -eq 'Failed') {
        "<span class='tool-badge tool-skipped' title='Failed to run'>&#x274C; $label (failed)</span>"
    } elseif ($status -eq 'Excluded') {
        "<span class='tool-badge tool-skipped' title='Excluded by user'>&#x2796; $label (excluded)</span>"
    } else {
        "<span class='tool-badge tool-skipped' title='Skipped (not configured or prereq missing)'>&#x26A0;&#xFE0F; $label (skipped)</span>"
    }
}

# --- Unique resource count estimate (unique Detail values as proxy) ---
$uniqueResources = @($findings | Select-Object -ExpandProperty Detail -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique).Count
if ($uniqueResources -eq 0) { $uniqueResources = $total }
$toolsUsed = $sourcesWithResults.Count

# --- Compliance framework coverage ---
$complianceHtml = ''
if (Get-Command Get-FrameworkCoverage -ErrorAction SilentlyContinue) {
    try {
        $coverage = @(Get-FrameworkCoverage -Findings $findings)
        if ($coverage.Count -gt 0) {
            $rows = foreach ($c in $coverage) {
                $colorMap = @{ green='#2e7d32'; yellow='#e65100'; red='#d32f2f' }
                $barColor = $colorMap[$c.Status]
                $label = HE "$($c.DisplayName) $($c.Version)"
                @"
<div class='bar-row' data-framework='$(HE $c.Framework)'>
  <span class='bar-label'>$label</span>
  <div class='bar-track'><div class='bar-fill' style='width:$($c.PercentCovered)%;background:$barColor;'></div></div>
  <span class='bar-count'>$($c.ControlsHit) / $($c.ControlsTotal) ($($c.PercentCovered)%)</span>
</div>
"@
            }
            $complianceHtml = @"
<h2>Compliance coverage</h2>
<div class='source-section' id='complianceSection'>
$($rows -join "`n")
</div>
"@
        }
    } catch {
        Write-Warning (Remove-Credentials "Compliance coverage computation failed: $_")
    }
}

$deltaBannerHtml = ''
$runModeBannerHtml = ''
if ($runMetadata) {
    $rmMode = if ($runMetadata.PSObject.Properties['runMode'] -and $runMetadata.runMode) { [string]$runMetadata.runMode } else { 'Full' }
    $rmSince = if ($runMetadata.PSObject.Properties['sinceUtc'] -and $runMetadata.sinceUtc) { [string]$runMetadata.sinceUtc } else { '' }
    $rmBaseline = if ($runMetadata.PSObject.Properties['baselineUtc'] -and $runMetadata.baselineUtc) { [string]$runMetadata.baselineUtc } else { '' }
    $rmModeClass = ($rmMode -replace '\s','').ToLowerInvariant()
    $sinceChip = if ($rmSince) { "<span class='run-chip since'>Since: $(HE $rmSince)</span>" } else { '' }
    $baseChip  = if ($rmBaseline) { "<span class='run-chip baseline'>Baseline: $(HE $rmBaseline)</span>" } else { '' }
    $toolBadges = ''
    if ($runMetadata.PSObject.Properties['tools'] -and $runMetadata.tools) {
        $perTool = foreach ($t in @($runMetadata.tools)) {
            $toolName = if ($t.PSObject.Properties['tool']) { [string]$t.tool } else { '' }
            $toolMode = if ($t.PSObject.Properties['runMode'] -and $t.runMode) { [string]$t.runMode } else { 'Full' }
            $cls = ($toolMode -replace '\s','').ToLowerInvariant()
            "<span class='run-chip mode-$cls' title='$(HE $toolName) - $(HE $toolMode)'>$(HE $toolName): $(HE $toolMode)</span>"
        }
        $toolBadges = $perTool -join ' '
    }
    $runModeBannerHtml = @"
<div class="run-mode-banner" role="region" aria-label="Run mode">
  <strong>Run mode:</strong>
  <span class="run-chip mode-$rmModeClass">$(HE $rmMode)</span>
  $sinceChip
  $baseChip
  <div class="run-tool-badges">$toolBadges</div>
</div>
"@
}
if ($deltaSummary) {
    $netClass = if ($deltaSummary.NetNonCompliantDelta -gt 0) { 'net-up' } elseif ($deltaSummary.NetNonCompliantDelta -lt 0) { 'net-down' } else { 'unchanged' }
    $netSign  = if ($deltaSummary.NetNonCompliantDelta -gt 0) { '+' } else { '' }
    $deltaBannerHtml = @"
<div class="delta-summary" role="region" aria-label="Delta vs previous run">
  <strong>Delta vs previous run:</strong>
  <span class="delta-chip new">$($deltaSummary.New) new</span>
  <span class="delta-chip resolved">$($deltaSummary.Resolved) resolved</span>
  <span class="delta-chip unchanged">$($deltaSummary.Unchanged) unchanged</span>
  <span class="delta-chip $netClass">Net non-compliant: $netSign$($deltaSummary.NetNonCompliantDelta)</span>
    </div>
"@
}

$portfolioSectionHtml = ''
if ($Portfolio -and $Portfolio.PSObject.Properties['Subscriptions']) {
    $portfolioSubs = @($Portfolio.Subscriptions)
    $portfolioCorrelations = if ($Portfolio.PSObject.Properties['Correlations']) { @($Portfolio.Correlations) } else { @() }
    $portfolioMgs = if ($Portfolio.PSObject.Properties['ManagementGroups']) { @($Portfolio.ManagementGroups) } else { @() }
    $portfolioSummary = if ($Portfolio.PSObject.Properties['Summary']) { $Portfolio.Summary } else { $null }
    $breadcrumbPath = @()

    if (@($portfolioMgs).Count -gt 0 -and $portfolioMgs[0].PSObject.Properties['ManagementGroupPath']) {
        $breadcrumbPath = @($portfolioMgs[0].ManagementGroupPath)
    } elseif (@($portfolioSubs).Count -gt 0 -and $portfolioSubs[0].PSObject.Properties['ManagementGroupPath']) {
        $breadcrumbPath = @($portfolioSubs[0].ManagementGroupPath)
    } elseif ($portfolioSummary -and $portfolioSummary.PSObject.Properties['ManagementGroupId'] -and $portfolioSummary.ManagementGroupId) {
        $breadcrumbPath = @([string]$portfolioSummary.ManagementGroupId)
    }

    if (@($portfolioSubs).Count -gt 0) {
        $heatmapRows = foreach ($sub in $portfolioSubs) {
            $anchorId = Get-AnchorId -text ([string]$sub.SubscriptionId)
            $subName = if ($sub.SubscriptionName) { [string]$sub.SubscriptionName } else { [string]$sub.SubscriptionId }
            $costText = if ($null -ne $sub.MonthlyCost -and [double]$sub.MonthlyCost -gt 0) {
                "{0:N2} {1}" -f [double]$sub.MonthlyCost, ($(if ($sub.Currency) { [string]$sub.Currency } else { 'USD' }))
            } else {
                'n/a'
            }
            "<tr><td><a href='#$anchorId'>$(HE $subName)</a></td><td>$(HE ([string]$sub.SubscriptionId))</td><td class='$(Get-HeatClass -Severity 'Critical' -Count ([int]$sub.SeverityCounts.Critical))'>$([int]$sub.SeverityCounts.Critical)</td><td class='$(Get-HeatClass -Severity 'High' -Count ([int]$sub.SeverityCounts.High))'>$([int]$sub.SeverityCounts.High)</td><td class='$(Get-HeatClass -Severity 'Medium' -Count ([int]$sub.SeverityCounts.Medium))'>$([int]$sub.SeverityCounts.Medium)</td><td class='$(Get-HeatClass -Severity 'Low' -Count ([int]$sub.SeverityCounts.Low))'>$([int]$sub.SeverityCounts.Low)</td><td class='$(Get-HeatClass -Severity 'Info' -Count ([int]$sub.SeverityCounts.Info))'>$([int]$sub.SeverityCounts.Info)</td><td>$([int]$sub.NonCompliantCount)</td><td>$(HE $costText)</td><td><span class='badge $(SeverityClass ([string]$sub.WorstSeverity))'>$(HE ([string]$sub.WorstSeverity))</span></td></tr>"
        }

        $subscriptionDetailsHtml = foreach ($sub in $portfolioSubs) {
            $anchorId = Get-AnchorId -text ([string]$sub.SubscriptionId)
            $subName = if ($sub.SubscriptionName) { [string]$sub.SubscriptionName } else { [string]$sub.SubscriptionId }

            $sourceChips = if ($sub.PSObject.Properties['SourceCounts'] -and @($sub.SourceCounts).Count -gt 0) {
                @($sub.SourceCounts | ForEach-Object { "<span class='source-chip'>$(HE $_.Source): $($_.Count)</span>" }) -join ' '
            } else {
                "<span class='source-chip'>No non-compliant findings</span>"
            }

            $topEntityRows = if ($sub.PSObject.Properties['TopEntities'] -and @($sub.TopEntities).Count -gt 0) {
                @($sub.TopEntities | ForEach-Object {
                    $entityName = if ($_.DisplayName) { $_.DisplayName } else { $_.EntityId }
                    "<tr><td>$(HE ([string]$entityName))</td><td>$(HE ([string]$_.EntityType))</td><td><span class='badge $(SeverityClass ([string]$_.WorstSeverity))'>$(HE ([string]$_.WorstSeverity))</span></td><td>$([int]$_.NonCompliantCount)</td><td>$([double]$_.MonthlyCost)</td></tr>"
                }) -join "`n"
            } else {
                "<tr><td colspan='5'>No top entities captured for this subscription.</td></tr>"
            }

            @"
<details id="$anchorId">
  <summary><strong>$(HE $subName)</strong> subscription details</summary>
  <div class="portfolio-detail">
    <p><strong>Management group path:</strong> $(HE ((@($sub.ManagementGroupPath) -join ' > ')))</p>
    <p><strong>By source:</strong> $sourceChips</p>
    <table class="findings-table">
      <thead>
        <tr><th>Top entity</th><th>Type</th><th>Worst severity</th><th>Non-compliant</th><th>Monthly cost</th></tr>
      </thead>
      <tbody>
        $topEntityRows
      </tbody>
    </table>
  </div>
</details>
"@
        }

        $correlationHtml = if (@($portfolioCorrelations).Count -gt 0) {
            $corrRows = foreach ($corr in $portfolioCorrelations) {
                "<tr><td>$(HE ([string]$corr.Title))</td><td><span class='badge $(SeverityClass ([string]$corr.Severity))'>$(HE ([string]$corr.Severity))</span></td><td>$([int]$corr.EvidenceCount)</td><td>$(HE ([string]$corr.Detail))</td></tr>"
            }
            @"
<h3>Cross-subscription identities</h3>
<table class="findings-table">
  <thead>
    <tr><th>Identity</th><th>Severity</th><th>Subscriptions</th><th>Detail</th></tr>
  </thead>
  <tbody>
    $($corrRows -join "`n")
  </tbody>
</table>
"@
        } else {
            "<p>No cross-subscription identity reuse was detected in this run.</p>"
        }

        $portfolioSectionHtml = @"
<h2>Portfolio rollup</h2>
<div class="source-section">
  <p class="portfolio-breadcrumb"><strong>Management group path:</strong> $(HE (($breadcrumbPath -join ' > ')))</p>
  <p class="subtitle">Subscriptions scanned: $(@($portfolioSubs).Count)</p>
  <div class="heatmap-wrap $(if (@($portfolioSubs).Count -gt 20) { 'heatmap-scroll' } else { '' })">
    <table class="heatmap-table">
      <thead>
        <tr><th>Subscription</th><th>ID</th><th>Critical</th><th>High</th><th>Medium</th><th>Low</th><th>Info</th><th>Non-compliant</th><th>Monthly cost</th><th>Worst</th></tr>
      </thead>
      <tbody>
        $($heatmapRows -join "`n")
      </tbody>
    </table>
  </div>
  $correlationHtml
  <h3>Subscription details</h3>
  $($subscriptionDetailsHtml -join "`n")
</div>
"@
    } else {
        $portfolioPathLabel = if (@($breadcrumbPath).Count -gt 0) { HE (($breadcrumbPath -join ' > ')) } else { 'n/a' }
        $portfolioSectionHtml = @"
<h2>Portfolio rollup</h2>
<div class="source-section">
  <p class="portfolio-breadcrumb"><strong>Management group path:</strong> $portfolioPathLabel</p>
  <p class="subtitle">Subscriptions scanned: 0</p>
  <p class="empty-state">No findings in portfolio.</p>
</div>
"@
    }
}

# Build inline SVG sparkline when trend data is provided (one point per run).
$sparklineHtml = ''
$trendArr = @($Trend | Where-Object { $_ })
if ($trendArr.Count -ge 2) {
    $svgW   = 200
    $svgH   = 40
    $padX   = 4
    $padY   = 4
    $plotW  = $svgW - 2 * $padX
    $plotH  = $svgH - 2 * $padY
    $vals   = @($trendArr | ForEach-Object { [int]$_.NonCompliant })
    $maxVal = ($vals | Measure-Object -Maximum).Maximum
    if ($maxVal -eq 0) { $maxVal = 1 }
    $step   = if ($vals.Count -gt 1) { $plotW / ($vals.Count - 1) } else { $plotW }
    $points = for ($i = 0; $i -lt $vals.Count; $i++) {
        $x = [math]::Round($padX + $i * $step, 1)
        $y = [math]::Round($padY + $plotH - ($vals[$i] / $maxVal) * $plotH, 1)
        "$x,$y"
    }
    $firstLabel = [string]$trendArr[0].RunId
    $lastLabel  = [string]$trendArr[-1].RunId
    $sparklineHtml = @"
<div class="trend-sparkline-wrap" role="img" aria-label="Trend: non-compliant findings over last $($trendArr.Count) runs">
  <span class="trend-label">Trend ($($trendArr.Count) runs):</span>
  <svg class="trend-sparkline" width="$svgW" height="$svgH" viewBox="0 0 $svgW $svgH" xmlns="http://www.w3.org/2000/svg">
    <polyline points="$($points -join ' ')" fill="none" stroke="#1565c0" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>
    <text x="$padX" y="$($svgH - 1)" font-size="8" fill="#666">$(HE $firstLabel)</text>
    <text x="$($svgW - $padX)" y="$($svgH - 1)" font-size="8" fill="#666" text-anchor="end">$(HE $lastLabel)</text>
  </svg>
</div>
"@
}


# --- Severity heatmap (ResourceGroup x Severity) ---
$heatmapSeverities = @('Critical','High','Medium','Low')
$rgSeverityMap = [ordered]@{}
foreach ($f in $findings) {
    $rg = Get-FindingResourceGroup $f
    if ([string]::IsNullOrWhiteSpace($rg)) { continue }
    $sev = [string]$f.Severity
    if ($heatmapSeverities -notcontains $sev) { continue }
    if (-not $rgSeverityMap.Contains($rg)) {
        $rgSeverityMap[$rg] = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Total = 0 }
    }
    $rgSeverityMap[$rg][$sev]++
    $rgSeverityMap[$rg]['Total']++
}

$heatmapHtml = ''
if ($rgSeverityMap.Count -gt 0) {
    # Compute per-severity max for proportional intensity (per column).
    $maxBySev = @{ Critical = 0; High = 0; Medium = 0; Low = 0 }
    foreach ($rg in $rgSeverityMap.Keys) {
        foreach ($sev in $heatmapSeverities) {
            if ($rgSeverityMap[$rg][$sev] -gt $maxBySev[$sev]) { $maxBySev[$sev] = $rgSeverityMap[$rg][$sev] }
        }
    }
    $sevColor = @{
        Critical = '127, 29, 29'    # #7f1d1d
        High     = '220, 38, 38'    # #dc2626
        Medium   = '245, 158, 11'   # #f59e0b
        Low      = '250, 204, 21'   # #facc15
    }
    # Sort RGs by total desc, then name asc
    $sortedRgs = @($rgSeverityMap.Keys | Sort-Object @{Expression={$rgSeverityMap[$_]['Total']};Descending=$true}, @{Expression={$_};Descending=$false})

    $headerCells = @('<div class="hm-cell hm-corner" role="columnheader" aria-label="Resource group">Resource group</div>')
    foreach ($sev in $heatmapSeverities) {
        $headerCells += "<div class='hm-cell hm-head hm-head-$($sev.ToLower())' role='columnheader'>$(HE $sev)</div>"
    }
    $headerRowHtml = ($headerCells -join '')

    $bodyRowsHtml = foreach ($rg in $sortedRgs) {
        $cells = @("<div class='hm-cell hm-rg' role='rowheader' title='$(HE $rg)'>$(HE $rg)</div>")
        foreach ($sev in $heatmapSeverities) {
            $count = [int]$rgSeverityMap[$rg][$sev]
            $maxC = [int]$maxBySev[$sev]
            $intensity = if ($count -le 0 -or $maxC -le 0) { 0.0 } else { [math]::Round(0.18 + 0.82 * ($count / [double]$maxC), 3) }
            $bg = if ($count -le 0) { 'transparent' } else { "rgba($($sevColor[$sev]), $intensity)" }
            $textColor = if ($count -le 0) { '#9ca3af' } elseif ($sev -in @('Medium','Low')) { '#1f2937' } else { '#fff' }
            $rgAttr = HE $rg
            $sevAttr = HE $sev
            $aria = "$count $sev finding$(if ($count -eq 1) { '' } else { 's' }) in resource group $rg"
            $cells += "<button type='button' class='hm-cell hm-data hm-data-$($sev.ToLower())' style='background:$bg;color:$textColor;' data-rg='$rgAttr' data-sev='$sevAttr' data-count='$count' aria-label='$(HE $aria). Click to filter.' onclick=`"filterByHeatmap('$rgAttr','$sevAttr')`">$count</button>"
        }
        ($cells -join '')
    }

    $heatmapHtml = @"
<section class="severity-heatmap-section" aria-labelledby="heatmap-title">
  <h2 id="heatmap-title" class="section-title">Findings by Resource Group x Severity</h2>
  <p class="hm-hint">Click a cell to filter the findings tables to that Resource Group + Severity combination.</p>
  <div class="severity-heatmap" role="grid" aria-label="Severity heatmap by resource group">
    <div class="hm-row hm-header-row" role="row">$headerRowHtml</div>
    $(foreach ($r in $bodyRowsHtml) { "<div class='hm-row' role='row'>$r</div>" })
  </div>
</section>
"@
}

# --- Framework coverage matrix (Framework x Tool) ---
$frameworkCoverageMatrixHtml = ''
$frameworkCatalog = [System.Collections.Generic.List[string]]::new()
foreach ($fw in $frameworkPriority) {
    if ($frameworkCatalog -notcontains $fw) { $frameworkCatalog.Add($fw) }
}
foreach ($src in $allSources) {
    $mapped = if ($sourceFrameworks.ContainsKey($src)) { @($sourceFrameworks[$src]) } else { @() }
    foreach ($fw in $mapped) {
        if ($frameworkCatalog -notcontains $fw) { $frameworkCatalog.Add($fw) }
    }
}

$frameworkCellMap = @{}
$frameworkTotals = @{}
$toolTotalsByFramework = @{}
$severityWeight = @{ Critical = 5; High = 4; Medium = 3; Low = 2; Info = 1 }

foreach ($fw in $frameworkCatalog) {
    $frameworkTotals[$fw] = 0
}
foreach ($src in $allSources) {
    $toolTotalsByFramework[$src] = 0
}

foreach ($f in $findings) {
    $src = [string]$f.Source
    if ($allSources -notcontains $src) { continue }
    $fws = @(Get-FindingFrameworkNames $f)
    if ($fws.Count -eq 0) { continue }
    foreach ($fw in $fws) {
        if ($frameworkCatalog -notcontains $fw) { continue }
        $key = "$src||$fw"
        if (-not $frameworkCellMap.ContainsKey($key)) {
            $frameworkCellMap[$key] = @{
                Count = 0
                Weighted = 0
                Severity = (New-SeverityCountMap)
            }
        }
        $frameworkCellMap[$key].Count++
        Add-SeverityToCountMap -Map $frameworkCellMap[$key].Severity -Severity ([string]$f.Severity)
        $normalizedSeverity = [string]$f.Severity
        $weight = if ($severityWeight.ContainsKey($normalizedSeverity)) { [int]$severityWeight[$normalizedSeverity] } else { 1 }
        $frameworkCellMap[$key].Weighted += $weight
        $frameworkTotals[$fw]++
        $toolTotalsByFramework[$src]++
    }
}

$matrixMaxWeighted = 0
foreach ($k in $frameworkCellMap.Keys) {
    if ([int]$frameworkCellMap[$k].Weighted -gt $matrixMaxWeighted) {
        $matrixMaxWeighted = [int]$frameworkCellMap[$k].Weighted
    }
}
if ($matrixMaxWeighted -lt 1) { $matrixMaxWeighted = 1 }

if ($frameworkCatalog.Count -gt 0 -and $allSources.Count -gt 0) {
    $headerCells = @("<th class='fxm-stub'>Framework</th>")
    foreach ($src in $allSources) {
        $headerCells += "<th title='$(HE $sourceLabels[$src])'>$(HE $sourceLabels[$src])</th>"
    }
    $headerCells += "<th class='fxm-summary-head'>Total</th>"

    $bodyRows = foreach ($fw in $frameworkCatalog) {
        $cells = @("<th class='fxm-framework' scope='row'>$(HE $fw)</th>")
        foreach ($src in $allSources) {
            $mapped = $sourceFrameworks.ContainsKey($src) -and (@($sourceFrameworks[$src]) -contains $fw)
            $key = "$src||$fw"
            $cell = if ($frameworkCellMap.ContainsKey($key)) { $frameworkCellMap[$key] } else { $null }
            $count = if ($cell) { [int]$cell.Count } else { 0 }
            $sevCounts = if ($cell) { $cell.Severity } else { New-SeverityCountMap }
            $weighted = if ($cell) { [int]$cell.Weighted } else { 0 }
            $intensity = if ($weighted -le 0) { 0 } else { [math]::Round([double]$weighted / [double]$matrixMaxWeighted, 3) }
            $alpha = if ($intensity -le 0) { 0 } else { [math]::Round(0.22 + (0.68 * $intensity), 3) }
            $bg = if ($weighted -le 0) { '#ffffff' } else { "rgba(21, 101, 192, $alpha)" }
            $txtColor = if ($intensity -gt 0.55) { '#ffffff' } else { '#1f2937' }
            $srcAttr = HE $src
            $fwAttr = HE $fw
            $countLabel = if ($count -eq 1) { '1 finding' } else { "$count findings" }
            if (-not $mapped) {
                $cells += "<td class='fxm-cell fxm-unmapped' title='Unmapped for $(HE $sourceLabels[$src])'>-</td>"
            } else {
                $sevHint = "Critical $([int]$sevCounts['Critical']) | High $([int]$sevCounts['High']) | Medium $([int]$sevCounts['Medium']) | Low $([int]$sevCounts['Low']) | Info $([int]$sevCounts['Info'])"
                if ($count -eq 0) {
                    $cells += "<td class='fxm-cell fxm-mapped-zero'><button type='button' class='fxm-button fxm-button-zero' data-source='$srcAttr' data-framework='$fwAttr' title='Mapped with no findings. Click to filter.' onclick=`"filterByFrameworkMatrix('$srcAttr','$fwAttr')`">&#x2713;<span class='fxm-cell-count'>0</span></button></td>"
                } else {
                    $cells += @"
<td class='fxm-cell fxm-mapped-hit'>
  <button type='button' class='fxm-button fxm-button-hit' data-source='$srcAttr' data-framework='$fwAttr' style='background:$bg;color:$txtColor' title='$(HE $countLabel). $sevHint. Click to filter.' onclick="filterByFrameworkMatrix('$srcAttr','$fwAttr')">
    <span class='fxm-cell-count'>$count</span>
    <span class='fxm-sev-mini'>
      <span class='fxm-sev-dot fxm-sev-critical' title='Critical $([int]$sevCounts['Critical'])'>$([int]$sevCounts['Critical'])</span>
      <span class='fxm-sev-dot fxm-sev-high' title='High $([int]$sevCounts['High'])'>$([int]$sevCounts['High'])</span>
      <span class='fxm-sev-dot fxm-sev-medium' title='Medium $([int]$sevCounts['Medium'])'>$([int]$sevCounts['Medium'])</span>
      <span class='fxm-sev-dot fxm-sev-low' title='Low $([int]$sevCounts['Low'])'>$([int]$sevCounts['Low'])</span>
      <span class='fxm-sev-dot fxm-sev-info' title='Info $([int]$sevCounts['Info'])'>$([int]$sevCounts['Info'])</span>
    </span>
  </button>
</td>
"@
                }
            }
        }
        $cells += "<td class='fxm-summary-cell'>$([int]$frameworkTotals[$fw])</td>"
        "<tr data-framework='$(HE $fw)'>$($cells -join '')</tr>"
    }

    $summaryCells = @("<th class='fxm-summary-head' scope='row'>Total</th>")
    foreach ($src in $allSources) {
        $summaryCells += "<td class='fxm-summary-cell'>$([int]$toolTotalsByFramework[$src])</td>"
    }
    $overallTotal = [int](@($frameworkTotals.Values | Measure-Object -Sum).Sum)
    $summaryCells += "<td class='fxm-summary-cell fxm-summary-total'>$overallTotal</td>"

    $frameworkCoverageMatrixHtml = @"
<section class="framework-matrix-section" aria-labelledby="framework-matrix-title">
  <h2 id="framework-matrix-title">Framework Coverage</h2>
  <p class="hm-hint">Click a mapped cell to filter findings by tool and framework intersection.</p>
  <div class="framework-matrix-wrap">
    <table id="framework-coverage-matrix" class="framework-matrix-table">
      <thead><tr>$($headerCells -join '')</tr></thead>
      <tbody>
        $($bodyRows -join "`n")
      </tbody>
      <tfoot><tr>$($summaryCells -join '')</tr></tfoot>
    </table>
  </div>
</section>
"@
}

# --- Priority stack: top Critical/High non-compliant findings ---
$priorityFindings = @($findings | Where-Object { -not $_.Compliant -and ($_.Severity -eq 'Critical' -or $_.Severity -eq 'High') } |
    Sort-Object @{Expression = { if ($_.Severity -eq 'Critical') { 0 } else { 1 } }}, Title)
$priorityStackHtml = ''
if ($priorityFindings.Count -gt 0) {
    $critBadge = if ($critical -gt 0) { "<span class='badge sev-critical'>$critical Critical</span>" } else { '' }
    $highBadge = if ($high -gt 0) { "<span class='badge sev-high'>$high High</span>" } else { '' }
    $priorityItems = ($priorityFindings | Select-Object -First 8 | ForEach-Object {
        $sevCls = SeverityClass $_.Severity
        $rem = if ($_.Remediation) { "<div class='priority-rem'>$(HE $_.Remediation)</div>" } else { '' }
        $titleText = if ($_.Title) { $_.Title } elseif ($_.Description) { $_.Description } else { '(no title)' }
        "<li><span class='badge $sevCls'>$(HE $_.Severity)</span> <strong>$(HE $titleText)</strong> <span class='priority-source'>[$(HE $_.Source)]</span>$rem</li>"
    }) -join "`n"
    $moreText = if ($priorityFindings.Count -gt 8) { "<li class='priority-more'>+ $($priorityFindings.Count - 8) more - use severity filter above</li>" } else { '' }
    $priorityStackHtml = @"
<div class="priority-stack">
  <div class="priority-header">$critBadge $highBadge <span class="priority-label">Requires immediate attention</span></div>
  <ul class="priority-list">
$priorityItems
$moreText
  </ul>
</div>
"@
}

# --- Source options for filter bar dropdown ---
$gfSourceOptions = ($sourcesWithResults | Sort-Object | ForEach-Object {
    $lbl = if ($sourceLabels.ContainsKey($_)) { $sourceLabels[$_] } else { $_ }
    "<option value=`"$(HE $_)`">$(HE $lbl)</option>"
}) -join "`n"
$gfFrameworkOptions = ($frameworkCatalog | Sort-Object | ForEach-Object {
    "<option value=`"$(HE $_)`">$(HE $_)</option>"
}) -join "`n"

# --- Summary tab (issue #210): embed exec dashboard content as the first tab ---
$summaryTabBodyHtml = ''
$summaryTabCss = ''
$summaryTabAvailable = $false
if (Get-Command Get-ExecDashboardModel -ErrorAction SilentlyContinue) {
    try {
        $summaryModel = Get-ExecDashboardModel -InputPath $InputPath
        $summaryTabBodyHtml = Get-ExecDashboardBody -Model $summaryModel -Embedded
        # Scope all exec-dashboard CSS under .exec-dash so it cannot collide with
        # report.html's own .card / .muted / .empty / .score / .delta-* rules.
        $summaryTabCss = Get-ExecDashboardCss -Scope '.exec-dash'
        $summaryTabAvailable = $true
    } catch {
        Write-Warning (Remove-Credentials "Summary tab render failed; falling back to Findings-only view: $_")
    }
}

# --- Resources tab (issue #209) -- entity-centric Resource Health view ---
$resourcesSectionHtml = ''
$resourcesModelJson = '{"entities":[]}'
if ($entities.Count -gt 0) {
    $rowsHtml = New-Object System.Collections.Generic.List[string]
    $idx = 0
    foreach ($e in $entities) {
        $idx++
        $name = if ($e.PSObject.Properties['EntityName'] -and $e.EntityName) { [string]$e.EntityName } else { [string]$e.EntityId }
        $type = if ($e.PSObject.Properties['EntityType']) { [string]$e.EntityType } else { '' }
        $platform = if ($e.PSObject.Properties['Platform']) { [string]$e.Platform } else { '' }
        $rg = if ($e.PSObject.Properties['ResourceGroup'] -and $e.ResourceGroup) { [string]$e.ResourceGroup } else { '' }
        $worst = if ($e.PSObject.Properties['WorstSeverity'] -and $e.WorstSeverity) { [string]$e.WorstSeverity } else { 'Info' }
        $nc = if ($e.PSObject.Properties['NonCompliantCount'] -and $null -ne $e.NonCompliantCount) { [int]$e.NonCompliantCount } else { 0 }
        $cc = if ($e.PSObject.Properties['CompliantCount'] -and $null -ne $e.CompliantCount) { [int]$e.CompliantCount } else { 0 }
        $sourcesText = if ($e.PSObject.Properties['Sources'] -and $e.Sources) { (@($e.Sources) -join ', ') } else { '' }
        $cost = if ($e.PSObject.Properties['MonthlyCost'] -and $null -ne $e.MonthlyCost -and [double]$e.MonthlyCost -gt 0) { '{0:N2}' -f [double]$e.MonthlyCost } else { '' }
        $sevClass = SeverityClass $worst

        $obsHtml = ''
        if ($e.PSObject.Properties['Observations'] -and $e.Observations) {
            $obsList = New-Object System.Collections.Generic.List[string]
            foreach ($o in @($e.Observations)) {
                $oSev = if ($o.PSObject.Properties['Severity'] -and $o.Severity) { [string]$o.Severity } else { 'Info' }
                $oDetail = if ($o.PSObject.Properties['Detail'] -and $o.Detail) { [string]$o.Detail } elseif ($o.PSObject.Properties['Title'] -and $o.Title) { [string]$o.Title } else { '' }
                $oRem = if ($o.PSObject.Properties['Remediation'] -and $o.Remediation) { [string]$o.Remediation } else { '' }
                $oDocs = if ($o.PSObject.Properties['DocsUrl'] -and $o.DocsUrl) { [string]$o.DocsUrl }
                         elseif ($o.PSObject.Properties['HelpUrl'] -and $o.HelpUrl) { [string]$o.HelpUrl }
                         elseif ($o.PSObject.Properties['DocsLink'] -and $o.DocsLink) { [string]$o.DocsLink }
                         else { '' }
                $docsCell = if ($oDocs) { "<a href=`"$(HE $oDocs)`" target=`"_blank`" rel=`"noopener noreferrer`">docs</a>" } else { '' }
                $obsList.Add("<tr><td><span class='badge $(SeverityClass $oSev)'>$(HE $oSev)</span></td><td>$(HE $oDetail)</td><td>$(HE $oRem)</td><td>$docsCell</td></tr>")
            }
            $obsHtml = $obsList -join "`n"
        }
        if (-not $obsHtml) {
            $obsHtml = "<tr><td colspan='4'><em>No observations recorded for this entity.</em></td></tr>"
        }

        $rowsHtml.Add(@"
<tr class="resource-row" data-platform="$(HE $platform)" data-severity="$(HE $worst)" data-entity-idx="$idx" onclick="toggleEntityDetail($idx)" tabindex="0">
  <td>$(HE $name)</td>
  <td>$(HE $type)</td>
  <td>$(HE $platform)</td>
  <td>$(HE $rg)</td>
  <td><span class="badge $sevClass">$(HE $worst)</span></td>
  <td>$nc</td>
  <td>$cc</td>
  <td>$(HE $sourcesText)</td>
  <td>$cost</td>
</tr>
<tr class="resource-detail" id="resource-detail-$idx" style="display:none">
  <td colspan="9">
    <table class="findings-table observations-table">
      <thead><tr><th>Severity</th><th>Detail</th><th>Remediation</th><th>Docs</th></tr></thead>
      <tbody>
$obsHtml
      </tbody>
    </table>
  </td>
</tr>
"@)
    }

    $resourcesSectionHtml = @"
<h2 id="resources">Resources</h2>
<div class="resources-section" data-tab="resources">
  <div class="filter-box no-print"><input type="text" placeholder="Filter resources..." onkeyup="filterTable(this,'resources-table')" class="filter-input"></div>
  <table class="findings-table" id="resources-table">
    <thead>
      <tr>
        <th onclick="sortTable(this)">Resource</th>
        <th onclick="sortTable(this)">Type</th>
        <th onclick="sortTable(this)">Platform</th>
        <th onclick="sortTable(this)">Resource Group</th>
        <th onclick="sortTable(this)">Worst Severity</th>
        <th onclick="sortTable(this)">Non-Compliant</th>
        <th onclick="sortTable(this)">Compliant</th>
        <th onclick="sortTable(this)">Sources</th>
        <th onclick="sortTable(this)">Monthly Cost</th>
      </tr>
    </thead>
    <tbody>
$($rowsHtml -join "`n")
    </tbody>
  </table>
</div>
"@

    # Embedded JSON model for client-side use; escape </ -> <\/ for safety
    $modelObj = [PSCustomObject]@{ entities = $entities }
    $resourcesModelJson = ($modelObj | ConvertTo-Json -Depth 12 -Compress) -replace '</', '<\/'
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Azure Analyzer Report</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif; font-size: 14px; color: #1a1a1a; background: #f5f5f5; padding: 24px; }
  h1 { font-size: 22px; margin-bottom: 4px; }
  h2 { font-size: 16px; margin: 24px 0 12px; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
  .subtitle { color: #666; font-size: 12px; margin-bottom: 24px; }

  /* Executive summary */
  .exec-summary { background: #fff; border-radius: 8px; padding: 24px 28px; margin-bottom: 24px; box-shadow: 0 2px 6px rgba(0,0,0,0.08); display: flex; gap: 28px; align-items: center; flex-wrap: wrap; }
  .donut { width: 140px; height: 140px; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
  .donut-inner { width: 90px; height: 90px; border-radius: 50%; background: #fff; display: flex; align-items: center; justify-content: center; font-size: 24px; font-weight: 700; }
  .exec-text { flex: 1; min-width: 200px; }
  .exec-text p { font-size: 15px; line-height: 1.6; color: #333; margin-bottom: 6px; }
  .exec-text .exec-highlight { font-size: 17px; font-weight: 600; color: #1a1a1a; }

  /* Stat cards */
  .cards { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 24px; }
  .card { background: #fff; border-radius: 6px; padding: 16px 20px; min-width: 120px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); border: 2px solid transparent; cursor: pointer; transition: border-color 0.2s, box-shadow 0.2s; }
  .card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.15); }
  .card:focus { outline: 2px solid #1565c0; outline-offset: 2px; }
  .card[aria-pressed="true"] { border-color: #1565c0; box-shadow: 0 2px 8px rgba(21,101,192,0.3); }
  .card-label { font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
  .card-value { font-size: 28px; font-weight: 700; margin-top: 2px; }
  .card-total .card-value { color: #1a1a1a; }
  .card-high .card-value { color: #d32f2f; }
  .card-medium .card-value { color: #e65100; }
  .card-low .card-value { color: #f9a825; }
  .card-ok .card-value { color: #2e7d32; }

  /* Per-source bars */
  .source-section { background: #fff; border-radius: 8px; padding: 20px 24px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  .bar-row { display: flex; align-items: center; margin-bottom: 8px; }
  .bar-label { width: 130px; font-size: 13px; font-weight: 500; flex-shrink: 0; }
  .bar-track { flex: 1; height: 20px; background: #eee; border-radius: 4px; overflow: hidden; margin: 0 10px; }
  .bar-fill { height: 100%; border-radius: 4px; transition: width 0.3s; }
  .bar-count { width: 40px; text-align: right; font-size: 13px; font-weight: 600; }

  /* Tool coverage */
  .tool-coverage { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 24px; }
  .tool-badge { display: inline-block; padding: 6px 14px; border-radius: 5px; font-size: 13px; font-weight: 500; }
  .tool-active { background: #e8f5e9; color: #1b5e20; }
  .tool-skipped { background: #fff3e0; color: #bf360c; }

  /* Portfolio rollup */
  .portfolio-breadcrumb { margin-bottom: 10px; color: #37474f; }
  .empty-state { margin-top: 8px; color: #546e7a; font-style: italic; }
  .heatmap-wrap { overflow-x: auto; margin-bottom: 16px; }
  .heatmap-scroll { max-height: 420px; overflow-y: auto; }
  .heatmap-table { width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 12px; }
  .heatmap-table th, .heatmap-table td { border: 1px solid #eceff1; padding: 8px 10px; text-align: left; }
  .heatmap-table th { background: #f5f7fa; }
  .heat-zero { background: #fafafa; color: #90a4ae; }
  .heat-critical { background: #ffebee; color: #b71c1c; font-weight: 700; }
  .heat-high { background: #fff3e0; color: #bf360c; font-weight: 700; }
  .heat-medium { background: #fff8e1; color: #ef6c00; font-weight: 700; }
  .heat-low { background: #fffde7; color: #827717; font-weight: 700; }
  .heat-info { background: #eceff1; color: #455a64; font-weight: 700; }
  .portfolio-detail { padding: 0 16px 12px; }
  .portfolio-detail p { margin: 8px 0; }
  .source-chip { display: inline-block; margin: 2px 6px 2px 0; padding: 4px 8px; border-radius: 999px; background: #edf2f7; color: #334155; font-size: 12px; }

  /* Findings tree */
  details { background: #fff; border-radius: 6px; margin-bottom: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  summary { padding: 12px 16px; cursor: pointer; user-select: none; font-size: 14px; }
  summary:hover { background: #f9f9f9; }
  .findings-tree { margin-bottom: 16px; }
  .tree-node { margin-bottom: 8px; }
  .tree-node .tree-children { padding: 0 12px 10px 16px; }
  .tree-node-category { margin-left: 10px; }
  .tree-node-rule { margin-left: 20px; }
  .tree-name { font-weight: 600; }
  .tree-count { font-size: 12px; color: #64748b; font-weight: 500; margin-left: 6px; }
  .tree-dots { display: inline-flex; gap: 6px; margin-left: 8px; vertical-align: middle; }
  .tree-dot {
    min-width: 22px; display: inline-flex; justify-content: center; align-items: center;
    border-radius: 999px; font-size: 11px; padding: 1px 6px; font-weight: 700;
    border: 1px solid transparent;
  }
  .tree-dot-critical { background: #fee2e2; color: #991b1b; border-color: #fecaca; }
  .tree-dot-high { background: #ffedd5; color: #9a3412; border-color: #fed7aa; }
  .tree-dot-medium { background: #fef3c7; color: #92400e; border-color: #fde68a; }
  .tree-dot-low { background: #dbeafe; color: #1d4ed8; border-color: #bfdbfe; }
  .tree-dot-info { background: #e5e7eb; color: #374151; border-color: #d1d5db; }
  .tree-finding {
    border: 1px solid #e2e8f0; border-radius: 8px; padding: 8px 10px; margin: 8px 0 0 0; background: #ffffff;
  }
  .tree-finding-header { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-bottom: 6px; }
  .tree-finding-title { font-size: 13px; }
  .tree-finding-meta { font-size: 12px; color: #334155; margin-top: 4px; }
  .tree-label { font-weight: 600; color: #0f172a; }
  .tree-hidden { display: none !important; }
  .tree-toolbar-actions { display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .tree-action {
    border: 1px solid #cbd5e1; border-radius: 999px; background: #fff; color: #1f2937;
    font-size: 0.75rem; font-weight: 700; padding: 0.2rem 0.6rem; cursor: pointer;
  }
  .tree-action:hover { background: #f1f5f9; }
  .findings-table { width: 100%; border-collapse: collapse; margin: 0 0 12px; font-size: 13px; }
  .findings-table th { background: #f0f0f0; padding: 8px 10px; text-align: left; font-weight: 600; cursor: pointer; white-space: nowrap; }
  .findings-table th:hover { background: #e0e0e0; }
  .findings-table td { padding: 7px 10px; border-top: 1px solid #f0f0f0; vertical-align: top; }
  .findings-table tr:nth-child(even) td { background: #fafafa; }
  .findings-table tr.sev-border-critical td:first-child { border-left: 3px solid #7f1d1d; }
  .findings-table tr.sev-border-high td:first-child { border-left: 3px solid #d32f2f; }
  .findings-table tr.sev-border-medium td:first-child { border-left: 3px solid #e65100; }
  .findings-table tr.sev-border-low td:first-child { border-left: 3px solid #f9a825; }
  .findings-table tr.sev-border-info td:first-child { border-left: 3px solid #bdbdbd; }
  .findings-table td a { color: #1565c0; word-break: break-all; }
  .findings-table td.resource-id { font-size: 11px; max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .findings-table tr:hover td { background: #fafafa; }
  .badge { display: inline-block; padding: 2px 7px; border-radius: 3px; font-size: 11px; font-weight: 600; }
  .sev-critical { background: #7f1d1d; color: #fff; }
  .sev-high { background: #fde8e8; color: #c62828; }
  .sev-medium { background: #fff3e0; color: #bf360c; }
  .sev-low { background: #fff9c4; color: #827717; }
  .sev-info { background: #eeeeee; color: #555; }
  .badge-ok { background: #e8f5e9; color: #1b5e20; }
  .badge-fail { background: #fce4ec; color: #880e4f; }
  .badge-new { background: #ffebee; color: #b71c1c; }
  .badge-resolved { background: #e8f5e9; color: #1b5e20; }
  .badge-unchanged { background: #eceff1; color: #37474f; }

  /* Compliance control badges (issue #212) */
  .control-badges { display: inline-flex; flex-wrap: wrap; gap: 4px; margin-left: 6px; vertical-align: middle; }
  .control-badge {
    display: inline-block; padding: 1px 6px; border-radius: 10px;
    font-size: 10.5px; font-weight: 600; line-height: 1.4;
    background: #eef2ff; color: #3730a3; border: 1px solid #c7d2fe;
    white-space: nowrap; max-width: 100%;
  }
  .control-badge.cb-cis   { background: #ecfdf5; color: #065f46; border-color: #a7f3d0; }
  .control-badge.cb-nist  { background: #eff6ff; color: #1e40af; border-color: #bfdbfe; }
  .control-badge.cb-pci   { background: #fef3c7; color: #92400e; border-color: #fde68a; }
  .control-badge.cb-iso   { background: #f3e8ff; color: #6b21a8; border-color: #e9d5ff; }
  .control-badge.cb-soc   { background: #fce7f3; color: #9d174d; border-color: #fbcfe8; }
  .control-badge.cb-hipaa { background: #ffedd5; color: #9a3412; border-color: #fed7aa; }
  .control-badge.cb-other { background: #f1f5f9; color: #334155; border-color: #cbd5e1; }
  @media (max-width: 600px) { .control-badge { font-size: 10px; padding: 1px 5px; } }

  /* Run mode banner */
  .run-mode-banner { background: #fff; border-radius: 8px; padding: 14px 20px; margin-bottom: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
  .run-mode-banner strong { font-size: 14px; }
  .run-chip { display: inline-block; padding: 3px 9px; border-radius: 4px; font-size: 12px; font-weight: 600; background: #eceff1; color: #37474f; }
  .run-chip.mode-full { background: #e3f2fd; color: #0d47a1; }
  .run-chip.mode-incremental { background: #e8f5e9; color: #1b5e20; }
  .run-chip.mode-cached { background: #fff8e1; color: #6d4c41; }
  .run-chip.mode-fullfallback { background: #fff3e0; color: #bf360c; }
  .run-chip.mode-partial { background: #f3e5f5; color: #4a148c; }
  .run-chip.since, .run-chip.baseline { background: #f5f5f5; color: #424242; font-weight: 500; }
  .run-tool-badges { display: flex; flex-wrap: wrap; gap: 6px; width: 100%; margin-top: 4px; }
  /* Delta summary */
  .delta-summary { background: #fff; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); display: flex; gap: 20px; flex-wrap: wrap; align-items: center; }
  .delta-summary strong { font-size: 16px; }
  .delta-chip { display: inline-block; padding: 4px 10px; border-radius: 4px; font-size: 13px; font-weight: 600; }
  .delta-chip.new { background: #ffebee; color: #b71c1c; }
  .delta-chip.resolved { background: #e8f5e9; color: #1b5e20; }
  .delta-chip.unchanged { background: #eceff1; color: #37474f; }
  .delta-chip.net-up { background: #ffebee; color: #b71c1c; }
  .delta-chip.net-down { background: #e8f5e9; color: #1b5e20; }
  .trend-sparkline-wrap { background: #fff; border-radius: 8px; padding: 12px 20px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); display: flex; gap: 12px; align-items: center; }
  .trend-label { font-size: 13px; font-weight: 600; color: #37474f; white-space: nowrap; }
  .trend-sparkline { display: block; overflow: visible; }

  /* Filter banner */
  .filter-banner { display: none; background: #e3f2fd; padding: 8px 16px; border-radius: 4px; margin-bottom: 16px; font-size: 13px; align-items: center; gap: 8px; }
  .filter-banner.active { display: flex; }
  .filter-banner button { background: #1565c0; color: #fff; border: none; border-radius: 3px; padding: 4px 10px; cursor: pointer; font-size: 12px; }
  .filter-banner button:hover { background: #0d47a1; }
  .severity-strip {
    display: flex; align-items: center; justify-content: space-between; gap: 0.75rem;
    position: sticky; top: 56px; z-index: 95;
    background: #ffffff; border-top: 1px solid #edf2f7; border-bottom: 1px solid #edf2f7;
    padding: 0.55rem 1rem;
  }
  .severity-strip-badges { display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap; }
  .severity-pill {
    border: 1px solid transparent; border-radius: 999px; padding: 0.2rem 0.6rem;
    font-size: 0.75rem; font-weight: 700; cursor: pointer; transition: box-shadow 0.12s, transform 0.12s;
  }
  .severity-pill:hover { transform: translateY(-1px); }
  .severity-pill[aria-pressed="true"], .severity-pill.is-active { box-shadow: 0 0 0 2px rgba(11, 18, 32, 0.18); }
  .severity-pill-critical { background: #fee2e2; color: #991b1b; border-color: #fecaca; }
  .severity-pill-high { background: #ffedd5; color: #9a3412; border-color: #fed7aa; }
  .severity-pill-medium { background: #fef3c7; color: #92400e; border-color: #fde68a; }
  .severity-pill-low { background: #dbeafe; color: #1d4ed8; border-color: #bfdbfe; }
  .severity-pill-info { background: #e5e7eb; color: #374151; border-color: #d1d5db; }
  .severity-pill-total { background: #f8fafc; color: #1f2937; border-color: #cbd5e1; white-space: nowrap; }

  /* Print-friendly styles */
  @media print {
    body { background: #fff; padding: 12px; }
    .no-print, .filter-box, .filter-input, .global-filter-bar { display: none !important; }
    .findings-table th { cursor: default; }
    .findings-table th:hover { background: #f0f0f0; }
    details { break-inside: avoid; }
    .findings-table tr { page-break-inside: avoid; }
    .exec-summary, .source-section, .card, details { box-shadow: none; border: 1px solid #ddd; }
    a { color: #1a1a1a; text-decoration: underline; }
  }
  /* Global filter bar */
  .global-filter-bar {
    display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center;
    padding: 0.6rem 1.5rem; background: #fff; border-bottom: 1px solid #e2e8f0;
    position: sticky; top: 0; z-index: 100; box-shadow: 0 2px 6px rgba(0,0,0,0.07);
    margin-bottom: 16px;
  }
  .gf-label { font-size: 0.78rem; font-weight: 600; color: #6b7280; white-space: nowrap; }
  .gf-chips { display: flex; gap: 0.35rem; align-items: center; flex-wrap: wrap; }
  .gf-chip {
    padding: 0.2rem 0.65rem; border-radius: 999px; border: 1.5px solid #e2e8f0;
    cursor: pointer; font-size: 0.75rem; font-weight: 600;
    background: transparent; color: #1a1a1a; transition: background 0.15s, color 0.15s;
  }
  .gf-chip.gf-active { background: #1565c0; color: #fff; border-color: #1565c0; }
  .gf-chip[data-active="true"][data-color="critical"] { background: #7f1d1d; color: #fff; border-color: #7f1d1d; }
  .gf-chip[data-active="true"][data-color="high"]     { background: #dc2626; color: #fff; border-color: #dc2626; }
  .gf-chip[data-active="true"][data-color="medium"]   { background: #f59e0b; color: #1f2937; border-color: #f59e0b; }
  .gf-chip[data-active="true"][data-color="low"]      { background: #facc15; color: #1f2937; border-color: #facc15; }
  .gf-chip[data-active="true"][data-color="info"]     { background: #6b7280; color: #fff; border-color: #6b7280; }
  .gf-count  { font-size: 0.75rem; color: #6b7280; white-space: nowrap; }
  .gf-rg-banner { font-size: 0.75rem; color: #1f2937; background: #eef2ff; border: 1px solid #c7d2fe; padding: 0.15rem 0.45rem; border-radius: 6px; white-space: nowrap; }
  .gf-rg-banner strong { color: #1e3a8a; margin: 0 0.15rem; }
  .gf-rg-clear { background: transparent; border: none; cursor: pointer; color: #6b7280; font-size: 0.75rem; padding: 0 0.15rem; }
  .gf-rg-clear:hover { color: #1f2937; }
  .gf-export, .gf-reset {
    padding: 0.25rem 0.65rem; border-radius: 6px; border: 1.5px solid #e2e8f0;
    cursor: pointer; font-size: 0.75rem; background: #fff; color: #1a1a1a; white-space: nowrap;
  }
  .gf-export:hover, .gf-reset:hover { background: #1565c0; color: #fff; border-color: #1565c0; }
  .gf-export select, .gf-filter-bar select { padding: 0.2rem 0.5rem; border-radius: 6px; border: 1.5px solid #e2e8f0; font-size: 0.75rem; background: #fff; }
  /* Priority stack */
  .priority-stack {
    background: #fdf2f2; border: 1px solid #f9c0c0; border-radius: 8px;
    padding: 1rem 1.25rem; margin-bottom: 1.5rem;
  }
  .priority-header { display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.75rem; flex-wrap: wrap; }
  .priority-label { font-size: 0.8rem; color: #6b7280; margin-left: 0.25rem; }
  .priority-list { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 0.4rem; }
  .priority-list li { font-size: 0.85rem; }
  .priority-rem { color: #6b7280; font-size: 0.78rem; margin-top: 0.15rem; padding-left: 1rem; }
  .priority-source { color: #6b7280; font-size: 0.78rem; }
  .priority-more { color: #6b7280; font-size: 0.78rem; font-style: italic; padding-top: 0.25rem; }
  .card-critical .card-value { color: #7f1d1d; }

  /* Issue #210: report-level tab navigation (Summary + Findings).
     Tab styles use rt- prefix to avoid collision with the embedded exec dashboard. */
  .rt-tabs { display: flex; gap: 4px; border-bottom: 2px solid #e2e8f0; margin: 0 0 16px; padding: 0; flex-wrap: wrap; }
  .rt-tab-button {
    background: transparent; border: none; border-bottom: 3px solid transparent;
    padding: 10px 18px; font-size: 14px; font-weight: 600; color: #57606a; cursor: pointer;
    margin-bottom: -2px; transition: color 0.15s, border-color 0.15s;
  }
  .rt-tab-button:hover { color: #1565c0; }
  .rt-tab-button:focus-visible { outline: 2px solid #1565c0; outline-offset: -2px; }
  .rt-tab-button.is-active { color: #0b1220; border-bottom-color: #1565c0; }
  .rt-tab-panel { display: none; }
  .rt-tab-panel.is-active { display: block; }
  @media print {
    .rt-tabs { display: none !important; }
    .rt-tab-panel { display: block !important; page-break-before: always; }
    .rt-tab-panel:first-of-type { page-break-before: auto; }
  }

  /* Severity heatmap (ResourceGroup x Severity) */
  .severity-heatmap-section { background: #fff; border-radius: 8px; padding: 18px 22px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  .hm-hint { font-size: 12px; color: #6b7280; margin-bottom: 10px; }
  .severity-heatmap { display: grid; grid-template-columns: minmax(180px, 1.6fr) repeat(4, minmax(70px, 1fr)); gap: 4px; align-items: stretch; }
  .severity-heatmap .hm-row { display: contents; }
  .hm-cell { padding: 8px 10px; font-size: 13px; border-radius: 4px; display: flex; align-items: center; justify-content: center; min-height: 34px; }
  .hm-corner { background: #f5f7fa; font-weight: 600; color: #374151; justify-content: flex-start; }
  .hm-head { background: #f5f7fa; font-weight: 700; font-size: 12px; text-transform: uppercase; letter-spacing: 0.4px; color: #374151; }
  .hm-head-critical { color: #7f1d1d; }
  .hm-head-high     { color: #dc2626; }
  .hm-head-medium   { color: #b45309; }
  .hm-head-low      { color: #a16207; }
  .hm-rg { background: #f9fafb; font-weight: 500; color: #1f2937; justify-content: flex-start; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .hm-data { border: 1px solid #e5e7eb; cursor: pointer; font-weight: 600; font-variant-numeric: tabular-nums; transition: transform 0.08s, box-shadow 0.12s; }
  .hm-data:hover { transform: scale(1.04); box-shadow: 0 2px 8px rgba(0,0,0,0.18); }
  .hm-data:focus-visible { outline: 2px solid #1565c0; outline-offset: 2px; }
  @media print {
    .hm-data { cursor: default; }
    .hm-data:hover { transform: none; box-shadow: none; }
  }
  .framework-matrix-section { background: #fff; border-radius: 8px; padding: 18px 22px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
  .framework-matrix-wrap { overflow-x: auto; }
  .framework-matrix-table { width: 100%; border-collapse: separate; border-spacing: 4px; min-width: 980px; }
  .framework-matrix-table th, .framework-matrix-table td { padding: 6px; text-align: center; font-size: 12px; }
  .framework-matrix-table thead th { background: #f8fafc; color: #334155; font-weight: 700; position: sticky; top: 0; z-index: 2; }
  .framework-matrix-table .fxm-stub { text-align: left; min-width: 160px; }
  .framework-matrix-table .fxm-framework { text-align: left; background: #f8fafc; color: #0f172a; font-weight: 600; position: sticky; left: 0; z-index: 1; }
  .framework-matrix-table .fxm-cell { border: 1px solid #e2e8f0; border-radius: 6px; background: #fff; }
  .framework-matrix-table .fxm-unmapped { color: #94a3b8; background: #f8fafc; }
  .framework-matrix-table .fxm-mapped-zero { background: #ecfdf5; color: #166534; border-color: #a7f3d0; }
  .framework-matrix-table .fxm-summary-cell, .framework-matrix-table .fxm-summary-head { background: #f8fafc; font-weight: 700; color: #1e293b; }
  .framework-matrix-table .fxm-summary-total { background: #e2e8f0; }
  .fxm-button { width: 100%; border: 0; border-radius: 5px; cursor: pointer; font-weight: 700; padding: 4px 3px; }
  .fxm-button:hover { transform: translateY(-1px); box-shadow: 0 1px 3px rgba(0,0,0,0.2); }
  .fxm-button-zero { background: transparent; color: #166534; }
  .fxm-cell-count { display: block; font-size: 13px; line-height: 1.1; }
  .fxm-sev-mini { margin-top: 3px; display: inline-flex; gap: 2px; }
  .fxm-sev-dot { min-width: 16px; border-radius: 999px; font-size: 9px; line-height: 1; padding: 2px 3px; font-weight: 700; border: 1px solid transparent; }
  .fxm-sev-critical { background: rgba(127,29,29,0.18); color: #7f1d1d; border-color: rgba(127,29,29,0.35); }
  .fxm-sev-high { background: rgba(220,38,38,0.18); color: #991b1b; border-color: rgba(220,38,38,0.35); }
  .fxm-sev-medium { background: rgba(245,158,11,0.22); color: #92400e; border-color: rgba(245,158,11,0.35); }
  .fxm-sev-low { background: rgba(59,130,246,0.2); color: #1d4ed8; border-color: rgba(59,130,246,0.35); }
  .fxm-sev-info { background: rgba(100,116,139,0.2); color: #334155; border-color: rgba(100,116,139,0.35); }
  /* Resources tab (issue #209) */
  .resources-section { margin-bottom: 1.5rem; }
  .resource-row { cursor: pointer; }
  .resource-row:hover { background: #f0f7ff; }
  .resource-row:focus-visible { outline: 2px solid #2563eb; outline-offset: -2px; }
  .observations-table { margin: 0.25rem 0; background: #fafafa; }
  .observations-table th { background: #eef2f7; }

$summaryTabCss
</style>
</head>
<body>
<h1>Azure Analyzer Report</h1>
<p class="subtitle">Generated: $date</p>

<!-- Issue #210: Summary tab (executive dashboard) is the default view; existing
     report content moves to Findings tab. Both render in print mode. -->
<nav class="rt-tabs no-print" role="tablist" aria-label="Report sections">
  <button class="rt-tab-button is-active" type="button" role="tab" id="rt-tab-summary-button"
          aria-selected="true" aria-controls="rt-tab-summary"
          data-tab="summary" onclick="rtSwitchTab(this,'summary')">Summary</button>
  <button class="rt-tab-button" type="button" role="tab" id="rt-tab-findings-button"
          aria-selected="false" aria-controls="rt-tab-findings"
          data-tab="findings" onclick="rtSwitchTab(this,'findings')">Findings</button>
</nav>

<section id="rt-tab-summary" class="rt-tab-panel is-active" role="tabpanel" aria-labelledby="rt-tab-summary-button">
  <div class="exec-dash">
$(if ($summaryTabAvailable) { $summaryTabBodyHtml } else { '<p class="empty">Summary unavailable for this run.</p>' })
  </div>
</section>

<section id="rt-tab-findings" class="rt-tab-panel" role="tabpanel" aria-labelledby="rt-tab-findings-button">
<!-- Executive Summary with Donut Chart -->
<div class="exec-summary">
  <div class="donut" style="background:conic-gradient(#2e7d32 0% $compliantPct%, #d32f2f $compliantPct% 100%);">
    <div class="donut-inner">$compliantPct%</div>
  </div>
  <div class="exec-text">
    <p class="exec-highlight">Scanned $uniqueResources resources across $toolsUsed tools. $compliantPct% compliant overall.</p>
    <p>$critical critical-severity and $high high-severity findings require immediate action.</p>
    <p>$medium medium-severity and $low low-severity findings also detected across $($byCategory.Count) categories.</p>
  </div>
</div>

<div class="cards">
  <button class="card card-total" onclick="filterBySeverity(this,'all')" aria-pressed="false"><div class="card-label">Total findings</div><div class="card-value">$total</div></button>
  <button class="card card-critical" onclick="filterBySeverity(this,'Critical')" aria-pressed="false"><div class="card-label">Critical (non-compliant)</div><div class="card-value">$critical</div></button>
  <button class="card card-high" onclick="filterBySeverity(this,'High')" aria-pressed="false"><div class="card-label">High (non-compliant)</div><div class="card-value">$high</div></button>
  <button class="card card-medium" onclick="filterBySeverity(this,'Medium')" aria-pressed="false"><div class="card-label">Medium (non-compliant)</div><div class="card-value">$medium</div></button>
  <button class="card card-low" onclick="filterBySeverity(this,'Low')" aria-pressed="false"><div class="card-label">Low (non-compliant)</div><div class="card-value">$low</div></button>
  <button class="card card-ok" onclick="filterBySeverity(this,'compliant')" aria-pressed="false"><div class="card-label">Compliant %</div><div class="card-value">$compliantPct%</div></button>
</div>
<div class="filter-banner" id="filterBanner">
  <span id="filterBannerText"></span>
  <button onclick="clearSeverityFilter()">Clear filter</button>
</div>

$runModeBannerHtml
$deltaBannerHtml
$sparklineHtml
$portfolioSectionHtml

$heatmapHtml
$frameworkCoverageMatrixHtml

<!-- Per-Source Breakdown -->
<h2>Findings by source</h2>
<div class="source-section">
$($sourceBarHtml -join "`n")
</div>

<!-- Tool Coverage Summary -->
<h2>Tool coverage</h2>
<div class="tool-coverage">
$($toolCoverageHtml -join "`n")
</div>

$complianceHtml

<h2>Findings by category</h2>

<!-- Global filter bar -->
<div class="global-filter-bar no-print" role="search" aria-label="Global finding filter" id="global-filter-bar">
  <div class="gf-chips" role="group" aria-label="Filter by severity">
    <span class="gf-label">Severity:</span>
    <button class="gf-chip gf-active" data-sev="all" onclick="toggleSevFilter(this,'all')">All</button>
    <button class="gf-chip" data-sev="Critical" data-color="critical" onclick="toggleSevFilter(this,'Critical')">Critical</button>
    <button class="gf-chip" data-sev="High"     data-color="high"     onclick="toggleSevFilter(this,'High')">High</button>
    <button class="gf-chip" data-sev="Medium"   data-color="medium"   onclick="toggleSevFilter(this,'Medium')">Medium</button>
    <button class="gf-chip" data-sev="Low"      data-color="low"      onclick="toggleSevFilter(this,'Low')">Low</button>
    <button class="gf-chip" data-sev="Info"     data-color="info"     onclick="toggleSevFilter(this,'Info')">Info</button>
  </div>
  <select id="gf-source" onchange="applyGlobalFilter()" aria-label="Filter by tool">
    <option value="">All Tools</option>
$gfSourceOptions
  </select>
  <select id="gf-framework" onchange="applyGlobalFilter()" aria-label="Filter by framework">
    <option value="">All Frameworks</option>
$gfFrameworkOptions
  </select>
  <select id="gf-platform" onchange="applyGlobalFilter()" aria-label="Filter by platform">
    <option value="">All Platforms</option>
    <option>Azure</option><option>Entra</option>
    <option>GitHub</option><option>ADO</option>
  </select>
  <select id="gf-status" onchange="applyGlobalFilter()" aria-label="Filter by compliance status">
    <option value="">All Status</option>
    <option value="false">Non-Compliant Only</option>
    <option value="true">Compliant Only</option>
  </select>
  <input id="gf-text" type="text" placeholder="Search findings…"
         oninput="applyGlobalFilter()" aria-label="Search findings" style="flex:1;min-width:150px;padding:0.2rem 0.5rem;border-radius:6px;border:1.5px solid #e2e8f0;">
  <button onclick="resetGlobalFilter()" class="gf-reset" title="Clear filters">✕ Clear</button>
  <span id="gf-count" class="gf-count" aria-live="polite"></span>
  <span id="gf-rg-banner" class="gf-rg-banner" style="display:none" aria-live="polite">RG: <strong class="gf-rg-name"></strong> <button type="button" class="gf-rg-clear" title="Clear resource group filter" onclick="_gfRg=''; applyGlobalFilter();">✕</button></span>
  <button onclick="exportFilteredCSV()" class="gf-export">⬇ CSV</button>
</div>

$priorityStackHtml

<div class="severity-strip no-print" role="group" aria-label="Severity totals for findings tree">
  <div class="severity-strip-badges">
    $($severityStripBadges -join "`n    ")
  </div>
  <div class="tree-toolbar-actions">
    <button type="button" class="severity-pill severity-pill-total is-active" data-severity="all" aria-pressed="true" onclick="filterBySeverityStrip(this,'all')">Total: $total</button>
    <button type="button" class="tree-action" onclick="setTreeExpansion(true)">Expand all</button>
    <button type="button" class="tree-action" onclick="setTreeExpansion(false)">Collapse all</button>
  </div>
</div>

<section id="findings-tree" class="findings-tree" aria-label="Collapsible findings tree">
$($findingsTreeHtml -join "`n")
</section>

$resourcesSectionHtml

<script type="application/json" id="report-model">$resourcesModelJson</script>
<script>
var activeSevFilter = null;

// --- Global filter state ---
var _gfActiveSev = new Set();
var _gfSource = '';
var _gfFramework = '';
var _gfPlatform = '';
var _gfStatus = '';
var _gfText = '';
var _gfRg = '';

function syncSeverityStripState() {
  var active = 'all';
  if (_gfActiveSev.size === 1) {
    active = Array.from(_gfActiveSev)[0];
  } else if (_gfActiveSev.size > 1) {
    active = '__multi__';
  }
  document.querySelectorAll('.severity-strip .severity-pill').forEach(function(pill) {
    var sev = pill.dataset.severity || '';
    var isActive = (active === 'all' && sev === 'all') || (active !== 'all' && active !== '__multi__' && sev === active);
    pill.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    pill.classList.toggle('is-active', isActive);
  });
}

function setSingleSeverityFilter(severity) {
  _gfActiveSev.clear();
  _gfRg = '';
  if (severity && severity !== 'all') {
    _gfActiveSev.add(severity);
  }
  document.querySelectorAll('.gf-chip').forEach(function(chip) {
    var chipSev = chip.dataset.sev || '';
    var on = (severity === 'all' && chipSev === 'all') || (severity !== 'all' && chipSev === severity);
    chip.dataset.active = on ? 'true' : 'false';
    chip.classList.toggle('gf-active', on);
  });
  applyGlobalFilter();
}

function filterBySeverityStrip(btn, severity) {
  setSingleSeverityFilter(severity || 'all');
}

function treeHasActiveFilter() {
  return _gfActiveSev.size > 0 || !!_gfSource || !!_gfFramework || !!_gfPlatform || !!_gfStatus || !!_gfText || !!_gfRg;
}

function syncFindingsTreeVisibility() {
  var activeFilter = treeHasActiveFilter();
  var nodes = Array.from(document.querySelectorAll('#findings-tree details.tree-node'));
  ['rule','category','tool'].forEach(function(level) {
    nodes.filter(function(node) { return node.dataset.treeLevel === level; }).forEach(function(node) {
      var visibleChildren = node.querySelectorAll('[data-tree-finding="true"]:not(.tree-hidden)').length;
      node.classList.toggle('tree-hidden', visibleChildren === 0);
      if (activeFilter && visibleChildren > 0) {
        node.open = true;
      }
    });
  });
}

function applyGlobalFilter() {
  _gfSource   = document.getElementById('gf-source') ? document.getElementById('gf-source').value : '';
  _gfFramework = document.getElementById('gf-framework') ? document.getElementById('gf-framework').value : '';
  _gfPlatform = document.getElementById('gf-platform') ? document.getElementById('gf-platform').value : '';
  _gfStatus   = document.getElementById('gf-status') ? document.getElementById('gf-status').value : '';
  _gfText     = (document.getElementById('gf-text') ? document.getElementById('gf-text').value : '').toLowerCase();

  var visible = 0;
  document.querySelectorAll('[data-tree-finding="true"]').forEach(function(row) {
    var sev      = row.dataset.severity || '';
    var source   = row.dataset.source || '';
    var platform = row.dataset.platform || '';
    var status   = row.dataset.compliant || '';
    var rg       = row.dataset.resourcegroup || '';
    var frameworks = (row.dataset.frameworks || '').toLowerCase();
    var text     = row.textContent.toLowerCase();

    var sevOk  = _gfActiveSev.size === 0 || _gfActiveSev.has(sev);
    var srcOk  = !_gfSource   || source   === _gfSource;
    var fwOk   = !_gfFramework || frameworks.split('|').includes(_gfFramework.toLowerCase());
    var platOk = !_gfPlatform || platform === _gfPlatform;
    var stOk   = !_gfStatus   || status   === _gfStatus;
    var rgOk   = !_gfRg       || rg       === _gfRg;
    var txtOk  = !_gfText     || text.includes(_gfText);

    var show = sevOk && srcOk && fwOk && platOk && stOk && rgOk && txtOk;
    row.classList.toggle('tree-hidden', !show);
    if (show) visible++;
  });

  var countEl = document.getElementById('gf-count');
  if (countEl) {
    var label = visible + ' finding' + (visible !== 1 ? 's' : '') + ' shown';
    if (_gfRg) { label += ' (RG: ' + _gfRg + ')'; }
    countEl.textContent = label;
  }
  var rgBanner = document.getElementById('gf-rg-banner');
  if (rgBanner) {
    if (_gfRg) {
      rgBanner.style.display = '';
      rgBanner.querySelector('.gf-rg-name').textContent = _gfRg;
    } else {
      rgBanner.style.display = 'none';
    }
  }
  syncFindingsTreeVisibility();
  syncSeverityStripState();
}

function toggleSevFilter(btn, sev) {
  if (sev === 'all') {
    _gfActiveSev.clear();
    _gfRg = '';
    document.querySelectorAll('.gf-chip').forEach(function(c) {
      c.dataset.active = 'false';
      if (c.dataset.sev === 'all') c.classList.add('gf-active');
      else c.classList.remove('gf-active');
    });
  } else {
    document.querySelector('.gf-chip[data-sev="all"]').classList.remove('gf-active');
    if (_gfActiveSev.has(sev)) { _gfActiveSev.delete(sev); btn.dataset.active = 'false'; }
    else { _gfActiveSev.add(sev); btn.dataset.active = 'true'; }
    if (_gfActiveSev.size === 0) {
      document.querySelector('.gf-chip[data-sev="all"]').classList.add('gf-active');
    }
  }
  applyGlobalFilter();
}

function resetGlobalFilter() {
  _gfActiveSev.clear();
  _gfSource = _gfFramework = _gfPlatform = _gfStatus = _gfText = _gfRg = '';
  document.querySelectorAll('.gf-chip').forEach(function(c) {
    c.dataset.active = 'false';
    if (c.dataset.sev === 'all') c.classList.add('gf-active');
    else c.classList.remove('gf-active');
  });
  ['gf-source','gf-framework','gf-platform','gf-status','gf-text'].forEach(function(id) {
    var el = document.getElementById(id); if (el) el.value = '';
  });
  applyGlobalFilter();
}

function filterByHeatmap(rg, sev) {
  // Toggle off if same RG+sev already active.
  if (_gfRg === rg && _gfActiveSev.size === 1 && _gfActiveSev.has(sev)) {
    resetGlobalFilter();
    return;
  }
  _gfRg = rg;
  _gfActiveSev.clear();
  _gfActiveSev.add(sev);
  document.querySelectorAll('.gf-chip').forEach(function(c) {
    c.classList.remove('gf-active');
    if (c.dataset.sev === sev) { c.dataset.active = 'true'; }
    else { c.dataset.active = 'false'; }
  });
  applyGlobalFilter();
  // Scroll to findings tables.
  var target = document.querySelector('details[id^="cat-"]') || document.getElementById('global-filter-bar');
  if (target && target.scrollIntoView) { target.scrollIntoView({behavior: 'smooth', block: 'start'}); }
}

function filterByFrameworkMatrix(source, framework) {
  if (!source || !framework) { return; }
  var normalizedFramework = framework.toLowerCase();
  var sameIntersection = (_gfSource === source && _gfFramework.toLowerCase() === normalizedFramework);
  if (sameIntersection) {
    resetGlobalFilter();
    return;
  }
  _gfSource = source;
  _gfFramework = framework;
  var sourceEl = document.getElementById('gf-source');
  if (sourceEl) { sourceEl.value = source; }
  var frameworkEl = document.getElementById('gf-framework');
  if (frameworkEl) { frameworkEl.value = framework; }
  applyGlobalFilter();
  var target = document.getElementById('global-filter-bar');
  if (target && target.scrollIntoView) { target.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
}

function treeStorageKey(path) {
  return 'azure-analyzer:findings-tree:' + path;
}

function persistTreeNodeState(node) {
  if (!node || !node.dataset || !node.dataset.treePath) return;
  try { localStorage.setItem(treeStorageKey(node.dataset.treePath), node.open ? '1' : '0'); } catch (_) {}
}

function restoreTreeNodeState(node) {
  if (!node || !node.dataset || !node.dataset.treePath) return;
  if ((node.dataset.treeLevel || '') === 'tool') { return; }
  try {
    var value = localStorage.getItem(treeStorageKey(node.dataset.treePath));
    if (value === '1') { node.open = true; }
    if (value === '0') { node.open = false; }
  } catch (_) {}
}

function setTreeExpansion(open) {
  document.querySelectorAll('#findings-tree details.tree-node').forEach(function(node) {
    if ((node.dataset.treeLevel || '') === 'tool') { return; }
    node.open = !!open;
    persistTreeNodeState(node);
  });
}

function initFindingsTree() {
  document.querySelectorAll('#findings-tree details.tree-node').forEach(function(node) {
    restoreTreeNodeState(node);
    node.addEventListener('toggle', function() { persistTreeNodeState(node); });
  });
}

function exportFilteredCSV() {
  var rows = Array.from(document.querySelectorAll('[data-tree-finding="true"]'))
    .filter(function(r) { return !r.classList.contains('tree-hidden'); });
  var headers = ['Title','Severity','Source','Platform','Compliant','Detail','Remediation','ResourceId'];
  var csvRows = [headers.join(',')];
  rows.forEach(function(r) {
    var titleEl = r.querySelector('.tree-finding-title');
    var detailRows = r.querySelectorAll('.tree-finding-meta');
    var detailText = detailRows[1] ? detailRows[1].textContent.replace(/^Description:\s*/,'') : '';
    var remediationText = detailRows[2] ? detailRows[2].textContent.replace(/^Fix:\s*/,'') : '';
    var resourceText = detailRows[0] ? detailRows[0].textContent.replace(/^Resource:\s*/,'') : '';
    var vals = [
      '"' + (titleEl ? titleEl.textContent : '').replace(/"/g, '""') + '"',
      '"' + (r.dataset.severity || '') + '"',
      '"' + (r.dataset.source || '') + '"',
      '"' + (r.dataset.platform || '') + '"',
      '"' + (r.dataset.compliant || '') + '"',
      '"' + detailText.replace(/"/g, '""') + '"',
      '"' + remediationText.replace(/"/g, '""') + '"',
      '"' + resourceText.replace(/"/g, '""') + '"'
    ];
    csvRows.push(vals.join(','));
  });
  var blob = new Blob([csvRows.join('\n')], {type: 'text/csv;charset=utf-8;'});
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'azure-analyzer-findings.csv';
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
}

// Initial count on load
document.addEventListener('DOMContentLoaded', function() {
  initFindingsTree();
  applyGlobalFilter();
});

function filterBySeverity(btn, severity) {
  var cards = document.querySelectorAll('.card');
  var banner = document.getElementById('filterBanner');
  var bannerText = document.getElementById('filterBannerText');
  if (activeSevFilter === severity) { clearSeverityFilter(); return; }
  activeSevFilter = severity;
  cards.forEach(function(c) { c.setAttribute('aria-pressed', 'false'); });
  btn.setAttribute('aria-pressed', 'true');
  document.getElementById('gf-status').value = '';
  if (severity === 'all') {
    setSingleSeverityFilter('all');
  } else if (severity === 'compliant') {
    setSingleSeverityFilter('all');
    document.getElementById('gf-status').value = 'true';
    applyGlobalFilter();
  } else {
    setSingleSeverityFilter(severity);
    document.getElementById('gf-status').value = 'false';
    applyGlobalFilter();
  }
  bannerText.textContent = severity === 'all' ? 'Showing all findings' : severity === 'compliant' ? 'Showing compliant findings only' : 'Showing ' + severity + ' severity findings only';
  banner.classList.add('active');
}
function clearSeverityFilter() {
  activeSevFilter = null;
  document.querySelectorAll('.card').forEach(function(c) { c.setAttribute('aria-pressed', 'false'); });
  document.getElementById('gf-status').value = '';
  setSingleSeverityFilter('all');
  document.getElementById('filterBanner').classList.remove('active');
}
function sortTable(th) {
  const table = th.closest('table');
  const tbody = table.querySelector('tbody');
  const rows = Array.from(tbody.querySelectorAll('tr'));
  const idx = Array.from(th.parentNode.children).indexOf(th);
  const asc = th.dataset.sort !== 'asc';
  th.dataset.sort = asc ? 'asc' : 'desc';
  rows.sort((a, b) => {
    const ta = a.cells[idx].textContent.trim();
    const tb = b.cells[idx].textContent.trim();
    return asc ? ta.localeCompare(tb) : tb.localeCompare(ta);
  });
  rows.forEach(r => tbody.appendChild(r));
}
function filterTable(input, tableId) {
  var filter = input.value.toLowerCase();
  var rows = document.getElementById(tableId).getElementsByTagName('tr');
  for (var i = 1; i < rows.length; i++) {
    rows[i].style.display = rows[i].textContent.toLowerCase().includes(filter) ? '' : 'none';
  }
}
function toggleEntityDetail(idx) {
  var d = document.getElementById('resource-detail-' + idx);
  if (!d) return;
  d.style.display = (d.style.display === 'none' || d.style.display === '') ? 'table-row' : 'none';
}
</script>
</section>
<script>
function rtSwitchTab(btn, key) {
  document.querySelectorAll('.rt-tab-button').forEach(function(b) {
    var on = b.dataset.tab === key;
    b.classList.toggle('is-active', on);
    b.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  document.querySelectorAll('.rt-tab-panel').forEach(function(p) {
    p.classList.toggle('is-active', p.id === 'rt-tab-' + key);
  });
}
</script>
</body>
</html>
"@

try {
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }
    $html = Remove-Credentials $html
    $html | Set-Content -Path $OutputPath -Encoding UTF8
} catch {
    Write-Error (Remove-Credentials "Failed to write HTML report to ${OutputPath}: $_")
    return
}
Write-Host "HTML report written to: $OutputPath" -ForegroundColor Green
