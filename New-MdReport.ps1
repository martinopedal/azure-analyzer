#Requires -Version 7.4
[CmdletBinding()]
param (
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.md'),
    [string] $TriagePath = '',
    [object] $Portfolio,
    [string] $BaselinePath = '',
    [object[]] $Trend = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$htmlSiblingReport = ([System.IO.Path]::GetFileNameWithoutExtension($OutputPath) + '.html')

$sanitizePath = Join-Path $PSScriptRoot 'modules' 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

function Sanitize([object]$Value) {
    if ($null -eq $Value) { return '' }
    return [string](Remove-Credentials ([string]$Value))
}

function SanitizeInline([object]$Value) {
    return (Sanitize $Value).Replace("`r", ' ').Replace("`n", ' ').Trim()
}

function MdCell([object]$Value) {
    return (SanitizeInline $Value) -replace '\|', '\\|'
}

function HasProp([object]$Obj, [string]$Name) {
    return $null -ne $Obj -and $Obj.PSObject.Properties.Match($Name).Count -gt 0
}

function GetProp([object]$Obj, [string]$Name, [object]$Default = '') {
    if (HasProp $Obj $Name) { return $Obj.$Name }
    return $Default
}

function GetSeverityRank([string]$Severity) {
    switch -Regex ($Severity) {
        '^(?i)critical$' { return 5 }
        '^(?i)high$' { return 4 }
        '^(?i)medium$' { return 3 }
        '^(?i)low$' { return 2 }
        default { return 1 }
    }
}

function GetSeverityGlyph([string]$Severity) {
    switch -Regex ($Severity) {
        '^(?i)critical$' { return '🔴' }
        '^(?i)high$' { return '🟠' }
        '^(?i)medium$' { return '🟡' }
        '^(?i)low$' { return '🟢' }
        default { return '⚪' }
    }
}

function GetSeverityWeight([string]$Severity) {
    switch -Regex ($Severity) {
        '^(?i)critical$' { return 5.0 }
        '^(?i)high$' { return 4.0 }
        '^(?i)medium$' { return 3.0 }
        '^(?i)low$' { return 2.0 }
        default { return 1.0 }
    }
}

function GetPostureGrade([int]$Score) {
    if ($Score -ge 90) { return 'A' }
    if ($Score -ge 80) { return 'B' }
    if ($Score -ge 70) { return 'C' }
    if ($Score -ge 60) { return 'D' }
    return 'F'
}

function GetSubscriptionFromFinding([object]$Finding) {
    $name = SanitizeInline (GetProp $Finding 'SubscriptionName' '')
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    $id = SanitizeInline (GetProp $Finding 'SubscriptionId' '')
    if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }
    $resourceId = SanitizeInline (GetProp $Finding 'ResourceId' '')
    if ($resourceId -match '/subscriptions/([^/]+)') { return $Matches[1] }
    if ($resourceId -match '/SUBSCRIPTIONS/([^/]+)') { return $Matches[1] }
    return '(tenant)'
}

function GetDomainFromFinding([object]$Finding) {
    $pillar = SanitizeInline (GetProp $Finding 'Pillar' '')
    if (-not [string]::IsNullOrWhiteSpace($pillar)) { return $pillar }
    $category = SanitizeInline (GetProp $Finding 'Category' '')
    if (-not [string]::IsNullOrWhiteSpace($category)) { return $category }
    return 'Uncategorized'
}

function GetRuleIdFromFinding([object]$Finding) {
    foreach ($candidate in @('RuleId', 'Rule', 'ControlId')) {
        $raw = SanitizeInline (GetProp $Finding $candidate '')
        if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw }
    }
    $title = SanitizeInline (GetProp $Finding 'Title' '')
    if ($title -match '^([A-Za-z][A-Za-z0-9._-]{2,})\s*[:\-]\s+') { return $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($title)) { return 'n/a' }
    return $title
}

function GetFrameworkNames([object]$Finding) {
    $names = New-Object System.Collections.Generic.List[string]
    $frameworks = GetProp $Finding 'Frameworks' @()
    if ((HasProp $Finding 'Frameworks') -and $frameworks) {
        foreach ($f in @($frameworks)) {
            $name = if ($f -is [string]) { SanitizeInline $f } elseif (HasProp $f 'Name') { SanitizeInline $f.Name } elseif (HasProp $f 'framework') { SanitizeInline $f.framework } else { SanitizeInline $f }
            if (-not [string]::IsNullOrWhiteSpace($name)) { $null = $names.Add($name) }
        }
    }
    $controls = GetProp $Finding 'Controls' @()
    if ($names.Count -eq 0 -and (HasProp $Finding 'Controls') -and $controls) {
        foreach ($c in @($controls)) {
            $control = SanitizeInline $c
            if (-not [string]::IsNullOrWhiteSpace($control)) { $null = $names.Add($control) }
        }
    }
    return @($names | Select-Object -Unique)
}

function GetStringArray([object]$Obj, [string]$Name) {
    if (-not (HasProp $Obj $Name)) { return @() }
    $raw = GetProp $Obj $Name @()
    return @($raw | ForEach-Object { SanitizeInline $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

$findings = @(Get-Content -Path $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)
$runDir = Split-Path $InputPath -Parent

$entities = @()
$entitiesPath = Join-Path $runDir 'entities.json'
if (Test-Path $entitiesPath) {
    try {
        $entitiesDoc = Get-Content -Path $entitiesPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if (HasProp $entitiesDoc 'Entities') { $entities = @($entitiesDoc.Entities) }
    } catch {
        Write-Warning (Sanitize "Could not parse entities.json: $_")
    }
}

$runMetadata = $null
$runMetadataPath = Join-Path $runDir 'run-metadata.json'
if (Test-Path $runMetadataPath) {
    try { $runMetadata = Get-Content -Path $runMetadataPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { }
}

$statusMap = @{}
$statusPath = Join-Path $runDir 'tool-status.json'
if (Test-Path $statusPath) {
    try {
        foreach ($s in @(Get-Content -Path $statusPath -Raw | ConvertFrom-Json -ErrorAction Stop)) {
            $statusMap[[string]$s.Tool] = [string]$s.Status
        }
    } catch { }
}

$manifestTools = @()
$manifestPath = Join-Path $PSScriptRoot 'tools' 'tool-manifest.json'
if (Test-Path $manifestPath) {
    try { $manifestTools = @((Get-Content -Path $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop).tools) } catch { }
}
$toolLabels = @{}
foreach ($tool in $manifestTools) {
    $toolName = SanitizeInline (GetProp $tool 'name' '')
    if ([string]::IsNullOrWhiteSpace($toolName)) { continue }
    $toolLabels[$toolName] = SanitizeInline (GetProp $tool 'displayName' $toolName)
}

$nonCompliant = @($findings | Where-Object { $_.Compliant -ne $true })
$total = $findings.Count
$critical = @($nonCompliant | Where-Object { $_.Severity -match '^(?i)critical$' }).Count
$high = @($nonCompliant | Where-Object { $_.Severity -match '^(?i)high$' }).Count
$medium = @($nonCompliant | Where-Object { $_.Severity -match '^(?i)medium$' }).Count
$low = @($nonCompliant | Where-Object { $_.Severity -match '^(?i)low$' }).Count
$info = @($nonCompliant | Where-Object { $_.Severity -notmatch '^(?i)(critical|high|medium|low)$' }).Count
$compliantCount = @($findings | Where-Object { $_.Compliant -eq $true }).Count
$compliancePct = if ($total -gt 0) { [math]::Round(($compliantCount / $total) * 100) } else { 0 }
$postureScore = $compliancePct
$postureGrade = GetPostureGrade -Score $postureScore

$tenant = SanitizeInline (GetProp $runMetadata 'tenantId' '')
if ([string]::IsNullOrWhiteSpace($tenant)) { $tenant = 'unknown' }
$runId = SanitizeInline (GetProp $runMetadata 'runId' '')
$scanStamp = SanitizeInline (GetProp $runMetadata 'startedAtUtc' '')
if ([string]::IsNullOrWhiteSpace($scanStamp)) { $scanStamp = (Get-Date -Format 'dd MMM yyyy HH:mm UTC') }

$sourceGroups = @{}
foreach ($f in $findings) {
    $src = SanitizeInline (GetProp $f 'Source' 'unknown')
    if (-not $sourceGroups.ContainsKey($src)) { $sourceGroups[$src] = [System.Collections.Generic.List[object]]::new() }
    $sourceGroups[$src].Add($f)
}

$versionByTool = @{}
foreach ($f in $findings) {
    $src = SanitizeInline (GetProp $f 'Source' '')
    if ([string]::IsNullOrWhiteSpace($src) -or $versionByTool.ContainsKey($src)) { continue }
    $v = SanitizeInline (GetProp $f 'ToolVersion' '')
    if (-not [string]::IsNullOrWhiteSpace($v)) { $versionByTool[$src] = $v }
}
if ($runMetadata -and (HasProp $runMetadata 'tools') -and $runMetadata.tools) {
    foreach ($t in @($runMetadata.tools)) {
        $toolName = SanitizeInline (GetProp $t 'tool' '')
        $toolVersion = SanitizeInline (GetProp $t 'version' '')
        if (-not [string]::IsNullOrWhiteSpace($toolName) -and -not [string]::IsNullOrWhiteSpace($toolVersion) -and -not $versionByTool.ContainsKey($toolName)) {
            $versionByTool[$toolName] = $toolVersion
        }
    }
}

$providerBuckets = @(
    [PSCustomObject]@{ Key = 'azure'; Heading = 'Azure (subscription / management group / tenant)'; Tools = [System.Collections.Generic.List[object]]::new() }
    [PSCustomObject]@{ Key = 'm365graph'; Heading = 'Microsoft 365 / Graph'; Tools = [System.Collections.Generic.List[object]]::new() }
    [PSCustomObject]@{ Key = 'github'; Heading = 'GitHub'; Tools = [System.Collections.Generic.List[object]]::new() }
    [PSCustomObject]@{ Key = 'ado'; Heading = 'Azure DevOps'; Tools = [System.Collections.Generic.List[object]]::new() }
    [PSCustomObject]@{ Key = 'other'; Heading = 'Other'; Tools = [System.Collections.Generic.List[object]]::new() }
)
foreach ($tool in $manifestTools) {
    $provider = SanitizeInline (GetProp $tool 'provider' '')
    $bucket = switch -Regex ($provider) {
        '^(?i)azure$' { 'azure' }
        '^(?i)(microsoft365|graph)$' { 'm365graph' }
        '^(?i)github$' { 'github' }
        '^(?i)ado$' { 'ado' }
        default { 'other' }
    }
    ($providerBuckets | Where-Object { $_.Key -eq $bucket } | Select-Object -First 1).Tools.Add($tool)
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Azure Analyzer - Posture Report')
$lines.Add('')
$runIdDisplay = if ([string]::IsNullOrWhiteSpace($runId)) { 'n/a' } else { $runId }
$tenantCell = MdCell $tenant
$scanCell = MdCell $scanStamp
$runIdCell = MdCell $runIdDisplay
$lines.Add('**Tenant:** `' + $tenantCell + '` &nbsp;|&nbsp; **Scanned:** ' + $scanCell + ' &nbsp;|&nbsp; **Run ID:** `' + $runIdCell + '`')
$lines.Add('')
$postureBadge = [uri]::EscapeDataString("$postureGrade ($postureScore/100)")
$toolCountBadge = @($manifestTools | Where-Object { $_.enabled }).Count
$runBadge = [uri]::EscapeDataString($scanStamp)
$lines.Add("![Critical](https://img.shields.io/badge/Critical-$critical-7f1d1d)")
$lines.Add("![High](https://img.shields.io/badge/High-$high-b91c1c)")
$lines.Add("![Medium](https://img.shields.io/badge/Medium-$medium-b45309)")
$lines.Add("![Low](https://img.shields.io/badge/Low-$low-a16207)")
$lines.Add("![Info](https://img.shields.io/badge/Info-$info-475569)")
$lines.Add("![Posture](https://img.shields.io/badge/Posture-$postureBadge-2563eb)")
$lines.Add("![Tools](https://img.shields.io/badge/Tools-$toolCountBadge-0369a1)")
$lines.Add("![Run](https://img.shields.io/badge/Run-$runBadge-334155)")
$lines.Add('')
$lines.Add('> Generated report. For full interactive exploration, open [' + (MdCell $htmlSiblingReport) + '](' + (MdCell $htmlSiblingReport) + ').')
$lines.Add('')
$lines.Add('## Contents')
$lines.Add('')
$lines.Add('1. [Executive summary](#executive-summary)')
$lines.Add('2. [Tool coverage](#tool-coverage)')
$lines.Add('3. [Heat map](#heat-map)')
$lines.Add('4. [Top 10 risks](#top-10-risks)')
$lines.Add('5. [Findings (top 30)](#findings-top-30)')
$lines.Add('6. [Entity inventory](#entity-inventory)')
$lines.Add('7. [Run details](#run-details)')
$lines.Add('')

$uniqueSubs = @($findings | ForEach-Object { GetSubscriptionFromFinding $_ } | Select-Object -Unique)
$entityCount = if ($entities.Count -gt 0) { $entities.Count } else { @($findings | Where-Object { -not [string]::IsNullOrWhiteSpace((SanitizeInline (GetProp $_ 'EntityId' ''))) }).Count }
$activeToolCount = @($manifestTools | Where-Object { $_.enabled }).Count
$lines.Add('## Executive summary')
$lines.Add('')
$lines.Add('Tenant `' + $tenantCell + '` was scanned across ' + $activeToolCount + ' tools covering ' + $entityCount + ' entities in ' + $uniqueSubs.Count + ' scope(s). Compliance is ' + $compliancePct + '%. Posture grade is **' + $postureGrade + ' (' + $postureScore + '/100)**.')
$lines.Add('')
if ($nonCompliant.Count -gt 0) {
    $lines.Add("$critical critical, $high high, $medium medium, $low low, and $info info findings are currently non-compliant.")
} else {
    $lines.Add('No non-compliant findings were detected in this run.')
}
$lines.Add('')

$pillarRollup = @(
    $nonCompliant |
        Group-Object -Property { GetDomainFromFinding $_ } |
        Sort-Object Count -Descending |
        Select-Object -First 8
)
if ($pillarRollup.Count -gt 0) {
    $lines.Add('### Pillar breakdown (non-compliant)')
    $lines.Add('')
    $lines.Add('| Pillar | Findings |')
    $lines.Add('| --- | ---: |')
    foreach ($bucket in $pillarRollup) {
        $lines.Add("| $(MdCell $bucket.Name) | $($bucket.Count) |")
    }
    $lines.Add('')
}

$lines.Add('## Tool coverage')
$lines.Add('')
if ($manifestTools.Count -eq 0) {
    $lines.Add('Tool manifest unavailable. No coverage table can be rendered.')
    $lines.Add('')
} else {
    foreach ($providerEntry in $providerBuckets) {
        $toolsInBucket = @($providerEntry.Tools)
        if ($toolsInBucket.Count -eq 0) { continue }
        $lines.Add("### $([string]$providerEntry.Heading)")
        $lines.Add('')
        $lines.Add('| Tool | Scope | Findings | Pass % | Status |')
        $lines.Add('| --- | --- | ---: | ---: | --- |')
        foreach ($tool in $toolsInBucket) {
            $name = SanitizeInline (GetProp $tool 'name' '')
            $scope = SanitizeInline (GetProp $tool 'scope' '')
            $enabled = [bool](GetProp $tool 'enabled' $false)
            $toolFindings = @($findings | Where-Object { (SanitizeInline (GetProp $_ 'Source' '')) -eq $name })
            $count = $toolFindings.Count
            $passPct = if ($count -gt 0) { [math]::Round((@($toolFindings | Where-Object { $_.Compliant -eq $true }).Count / $count) * 100) } else { 0 }
            $status = if (-not $enabled) {
                '_skipped_'
            } elseif ($statusMap.ContainsKey($name)) {
                $raw = SanitizeInline $statusMap[$name]
                if ($raw -match '^(?i)success$') { 'OK' } elseif ($raw -match '^(?i)skipped$') { '_skipped_' } else { MdCell $raw }
            } elseif ($count -gt 0) {
                'OK'
            } else {
                '_skipped_'
            }
            $passText = if ($count -gt 0) { "$passPct%" } else { '-' }
            $lines.Add("| $(MdCell $name) | $(MdCell $scope) | $count | $passText | $status |")
        }
        $lines.Add('')
    }
}

$lines.Add('## Heat map')
$lines.Add('')
$lines.Add('Findings by control domain (rows) and subscription (columns). Cell glyph indicates the highest severity present and includes the finding count.')
$lines.Add('')

$domainList = @($nonCompliant | ForEach-Object { GetDomainFromFinding $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$subList = @($nonCompliant | ForEach-Object { GetSubscriptionFromFinding $_ } | Sort-Object -Unique)

if ($domainList.Count -gt 0 -and $subList.Count -gt 0) {
    $lines.Add('| Control domain | ' + (($subList | ForEach-Object { MdCell $_ }) -join ' | ') + ' | Total |')
    $lines.Add('| --- | ' + (($subList | ForEach-Object { ':---:' }) -join ' | ') + ' | ---: |')
    foreach ($domain in $domainList) {
        $rowTotal = 0
        $cells = New-Object System.Collections.Generic.List[string]
        foreach ($sub in $subList) {
            $slice = @($nonCompliant | Where-Object { (GetDomainFromFinding $_) -eq $domain -and (GetSubscriptionFromFinding $_) -eq $sub })
            $count = $slice.Count
            $rowTotal += $count
            if ($count -gt 0) {
                $max = ($slice | ForEach-Object { GetSeverityRank (SanitizeInline (GetProp $_ 'Severity' 'Info')) } | Measure-Object -Maximum).Maximum
                $sev = switch ($max) { 5 { 'Critical' } 4 { 'High' } 3 { 'Medium' } 2 { 'Low' } default { 'Info' } }
                $cells.Add("$(GetSeverityGlyph $sev) $count")
            } else {
                $cells.Add('⚪ 0')
            }
        }
        $lines.Add("| $(MdCell $domain) | $($cells -join ' | ') | $rowTotal |")
    }
} elseif ($manifestTools.Count -gt 0) {
    $lines.Add('| Tool | Critical | High | Medium | Low | Info | Total |')
    $lines.Add('| --- | :---: | :---: | :---: | :---: | :---: | ---: |')
    foreach ($tool in $manifestTools) {
        $name = SanitizeInline (GetProp $tool 'name' '')
        $toolFindings = @($nonCompliant | Where-Object { (SanitizeInline (GetProp $_ 'Source' '')) -eq $name })
        $c = @($toolFindings | Where-Object { $_.Severity -match '^(?i)critical$' }).Count
        $h = @($toolFindings | Where-Object { $_.Severity -match '^(?i)high$' }).Count
        $m = @($toolFindings | Where-Object { $_.Severity -match '^(?i)medium$' }).Count
        $l = @($toolFindings | Where-Object { $_.Severity -match '^(?i)low$' }).Count
        $i = @($toolFindings | Where-Object { $_.Severity -notmatch '^(?i)(critical|high|medium|low)$' }).Count
        $lines.Add("| $(MdCell $name) | 🔴 $c | 🟠 $h | 🟡 $m | 🟢 $l | ⚪ $i | $($toolFindings.Count) |")
    }
} else {
    $lines.Add('No findings available to render a heat map.')
}
$lines.Add('')
$lines.Add('Legend: 🔴 Critical, 🟠 High, 🟡 Medium, 🟢 Low, ⚪ Info')
$lines.Add('')

$lines.Add('## Top 10 risks')
$lines.Add('')
if ($nonCompliant.Count -eq 0) {
    $lines.Add('No non-compliant findings to rank.')
    $lines.Add('')
} else {
    $riskRows = @(
        $nonCompliant |
            Group-Object -Property { "$(GetRuleIdFromFinding $_)|$(GetDomainFromFinding $_)|$(SanitizeInline (GetProp $_ 'Source' ''))" } |
            ForEach-Object {
                $groupItems = @($_.Group)
                $best = $groupItems | Sort-Object @{ Expression = { GetSeverityRank (SanitizeInline (GetProp $_ 'Severity' 'Info')) }; Descending = $true } | Select-Object -First 1
                $entityKeys = @($groupItems | ForEach-Object {
                    $id = SanitizeInline (GetProp $_ 'EntityId' '')
                    if ([string]::IsNullOrWhiteSpace($id)) { $id = SanitizeInline (GetProp $_ 'ResourceId' '') }
                    if ([string]::IsNullOrWhiteSpace($id)) { $id = SanitizeInline (GetProp $_ 'Id' '') }
                    $id
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
                $severity = SanitizeInline (GetProp $best 'Severity' 'Info')
                [PSCustomObject]@{
                    Severity = $severity
                    Rule = GetRuleIdFromFinding $best
                    Domain = GetDomainFromFinding $best
                    Tool = SanitizeInline (GetProp $best 'Source' '')
                    Findings = $groupItems.Count
                    Score = ([double](GetSeverityWeight $severity) * [double]([math]::Max(1, $entityKeys.Count)))
                }
            } |
            Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { GetSeverityRank $_.Severity }; Descending = $true }, @{ Expression = { $_.Findings }; Descending = $true }, Rule |
            Select-Object -First 10
    )
    $lines.Add('| # | Severity | Rule | Domain | Tool | Findings |')
    $lines.Add('| ---: | --- | --- | --- | --- | ---: |')
    $idx = 1
    foreach ($r in $riskRows) {
        $lines.Add("| $idx | $(GetSeverityGlyph $r.Severity) $(MdCell $r.Severity) | $(MdCell $r.Rule) | $(MdCell $r.Domain) | $(MdCell $r.Tool) | $($r.Findings) |")
        $idx++
    }
    $lines.Add('')
}

$lines.Add('## Findings (top 30)')
$lines.Add('')
$lines.Add("Top 30 findings from this run. The [interactive HTML report]($htmlSiblingReport) renders the full set.")
$lines.Add('')

$frameworkSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $findings) {
    foreach ($fw in @(GetFrameworkNames $f)) { $null = $frameworkSet.Add($fw) }
}
if ($frameworkSet.Count -gt 0) {
    $lines.Add('### Framework reference')
    $lines.Add('')
    $lines.Add('| Framework | Badge text |')
    $lines.Add('| --- | --- |')
    foreach ($fw in @($frameworkSet | Sort-Object)) {
        $lines.Add("| $(MdCell $fw) | `[[$(MdCell $fw)]]` |")
    }
    $lines.Add('')
}

$topFindingsSource = if ($nonCompliant.Count -gt 0) { $nonCompliant } else { $findings }
$topFindings = @(
    $topFindingsSource |
        Sort-Object @{ Expression = { GetSeverityRank (SanitizeInline (GetProp $_ 'Severity' 'Info')) }; Descending = $true }, @{ Expression = { GetDomainFromFinding $_ } }, @{ Expression = { SanitizeInline (GetProp $_ 'Title' '') } } |
        Select-Object -First 30
)

if ($topFindings.Count -eq 0) {
    $lines.Add('No findings available.')
    $lines.Add('')
} else {
    $lines.Add('| # | Sev | Rule ID | Rule | Frameworks | Entity | Sub | Tool | Status |')
    $lines.Add('| ---: | --- | --- | --- | --- | --- | --- | --- | --- |')
    $idx = 1
    foreach ($f in $topFindings) {
        $severity = SanitizeInline (GetProp $f 'Severity' 'Info')
        $frameworks = @((GetFrameworkNames $f) | ForEach-Object { MdCell $_ })
        $frameworkText = if ($frameworks.Count -gt 0) { $frameworks -join ' · ' } else { '-' }
        $entity = SanitizeInline (GetProp $f 'EntityId' '')
        if ([string]::IsNullOrWhiteSpace($entity)) { $entity = SanitizeInline (GetProp $f 'ResourceId' '') }
        if ([string]::IsNullOrWhiteSpace($entity)) { $entity = '(unknown)' }
        $status = SanitizeInline (GetProp $f 'Status' '')
        if ([string]::IsNullOrWhiteSpace($status)) { $status = if ($f.Compliant -eq $true) { 'Pass' } else { 'Open' } }
        $ruleCell = MdCell (GetRuleIdFromFinding $f)
        $entityCell = MdCell $entity
        $lines.Add("| $idx | $(GetSeverityGlyph $severity) | ``$ruleCell`` | $(MdCell (GetProp $f 'Title' '')) | $frameworkText | ``$entityCell`` | $(MdCell (GetSubscriptionFromFinding $f)) | $(MdCell (GetProp $f 'Source' '')) | $(MdCell $status) |")
        $idx++
    }
    $lines.Add('')
}

$schema22Findings = @(
    $nonCompliant |
        Where-Object {
            (HasProp $_ 'Pillar') -or (HasProp $_ 'DeepLinkUrl') -or (HasProp $_ 'RemediationSnippets') -or
            (HasProp $_ 'MitreTactics') -or (HasProp $_ 'MitreTechniques') -or (HasProp $_ 'BaselineTags') -or (HasProp $_ 'EntityRefs')
        } |
        Sort-Object @{ Expression = { GetSeverityRank (SanitizeInline (GetProp $_ 'Severity' 'Info')) }; Descending = $true }, @{ Expression = { SanitizeInline (GetProp $_ 'Title' '') } } |
        Select-Object -First 10
)
if ($schema22Findings.Count -gt 0) {
    $lines.Add('## Schema 2.2 spotlight')
    $lines.Add('')
    $lines.Add('| # | Tool | Pillar | Impact | Effort | Frameworks | MITRE | Deep link |')
    $lines.Add('| ---: | --- | --- | --- | --- | --- | --- | --- |')
    $spot = 1
    foreach ($f in $schema22Findings) {
        $toolName = SanitizeInline (GetProp $f 'Source' '')
        $toolDisplay = if ($toolLabels.ContainsKey($toolName)) { $toolLabels[$toolName] } else { $toolName }
        $frameworkText = @((GetFrameworkNames $f) | ForEach-Object { MdCell $_ }) -join ' · '
        if ([string]::IsNullOrWhiteSpace($frameworkText)) { $frameworkText = '-' }
        $tactics = @(GetStringArray -Obj $f -Name 'MitreTactics')
        $techniques = @(GetStringArray -Obj $f -Name 'MitreTechniques')
        $mitreText = @($tactics + $techniques) -join ', '
        if ([string]::IsNullOrWhiteSpace($mitreText)) { $mitreText = '-' }
        $deep = SanitizeInline (GetProp $f 'DeepLinkUrl' '')
        $deepCell = if ([string]::IsNullOrWhiteSpace($deep)) { '-' } else { "[Open]($deep)" }
        $lines.Add("| $spot | $(MdCell $toolDisplay) | $(MdCell (GetProp $f 'Pillar' '-')) | $(MdCell (GetProp $f 'Impact' '-')) | $(MdCell (GetProp $f 'Effort' '-')) | $frameworkText | $(MdCell $mitreText) | $deepCell |")
        $spot++
    }
    $lines.Add('')
    $lines.Add('### Evidence and remediation snippets')
    $lines.Add('')
    foreach ($f in $schema22Findings) {
        $title = MdCell (GetProp $f 'Title' 'Untitled finding')
        $lines.Add("<details><summary>$title</summary>")
        $lines.Add('')
        $baselineTags = @(GetStringArray -Obj $f -Name 'BaselineTags')
        if ($baselineTags.Count -gt 0) {
            $lines.Add('- **Baseline tags:** ' + (($baselineTags | ForEach-Object { "`"$($_)`"" }) -join ', '))
        }
        $entityRefs = @(GetStringArray -Obj $f -Name 'EntityRefs')
        if ($entityRefs.Count -gt 0) {
            $lines.Add('- **Entity refs:** `' + (($entityRefs | ForEach-Object { $_ }) -join '`, `') + '`')
        }
        $evidenceUris = @(GetStringArray -Obj $f -Name 'EvidenceUris')
        if ($evidenceUris.Count -gt 0) {
            $lines.Add('- **Evidence URIs:**')
            foreach ($uri in $evidenceUris) { $lines.Add("  - [$uri]($uri)") }
        }
        $snippets = if (HasProp $f 'RemediationSnippets') { $f.RemediationSnippets } else { @() }
        if (@($snippets).Count -gt 0) {
            $lines.Add('- **Remediation snippets:**')
            foreach ($sn in @($snippets)) {
                $lang = if (HasProp $sn 'language') { SanitizeInline $sn.language } elseif (HasProp $sn 'Language') { SanitizeInline $sn.Language } else { 'text' }
                $code = if (HasProp $sn 'code') { [string]$sn.code } elseif (HasProp $sn 'Code') { [string]$sn.Code } elseif (HasProp $sn 'Snippet') { [string]$sn.Snippet } else { [string]$sn }
                $lines.Add(('  ```' + $lang))
                $lines.Add((Remove-Credentials $code))
                $lines.Add('  ```')
            }
        }
        $lines.Add('')
        $lines.Add('</details>')
        $lines.Add('')
    }
}

$lines.Add('## Entity inventory')
$lines.Add('')
if ($entities.Count -gt 0) {
    $lines.Add("$($entities.Count) entities discovered across all scopes.")
    $lines.Add('')
    $lines.Add('| Entity type | Count |')
    $lines.Add('| --- | ---: |')
    foreach ($g in @($entities | Group-Object -Property { SanitizeInline (GetProp $_ 'EntityType' 'Other') } | Sort-Object Name)) {
        $name = if ([string]::IsNullOrWhiteSpace($g.Name)) { 'Other' } else { $g.Name }
        $lines.Add("| $(MdCell $name) | $($g.Count) |")
    }
    $lines.Add('')
} else {
    $lines.Add('No entity inventory was produced for this run.')
    $lines.Add('')
}

$lines.Add('## Run details')
$lines.Add('')
$lines.Add('<details>')
$lines.Add('<summary>Tool versions</summary>')
$lines.Add('')
$lines.Add('| Tool | Version | Provider |')
$lines.Add('| --- | --- | --- |')
if ($manifestTools.Count -gt 0) {
    foreach ($tool in $manifestTools) {
        $name = SanitizeInline (GetProp $tool 'name' '')
        $version = if ($versionByTool.ContainsKey($name)) { $versionByTool[$name] } else { '-' }
        $provider = SanitizeInline (GetProp $tool 'provider' '')
        $lines.Add("| $(MdCell $name) | $(MdCell $version) | $(MdCell $provider) |")
    }
} else {
    $lines.Add('| n/a | n/a | n/a |')
}
$lines.Add('')
$lines.Add('</details>')
$lines.Add('')
$lines.Add('Generated by **azure-analyzer**. Schema fields are consumed defensively and optional Schema 2.2 fields render when present.')

try {
    $outDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
    $final = Remove-Credentials ($lines -join "`n")
    $final | Set-Content -Path $OutputPath -Encoding UTF8 -NoNewline
} catch {
    Write-Error (Sanitize "Failed to write Markdown report to ${OutputPath}: $_")
    return
}

Write-Host "Markdown report written to: $OutputPath" -ForegroundColor Green
