#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $InputPath = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output' 'report.html'),
    [string] $TriagePath = '',
    [string] $PreviousRun = '',
    [object] $Portfolio,
    [object[]] $Trend = @(),
    [int] $TopRecommendationsCount = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'modules' 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

if (-not (Test-Path $InputPath)) {
    throw "Results file not found: $InputPath. Run Invoke-AzureAnalyzer.ps1 first."
}

function SafeText([object]$Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return (Remove-Credentials ((@($Value | ForEach-Object { [string]$_ }) -join ', ')))
    }
    return (Remove-Credentials ([string]$Value))
}

function HE([object]$Value) {
    $s = SafeText $Value
    return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'","&#39;")
}

function Get-SeverityKey([string]$Severity) {
    switch -Regex (($Severity ?? '').Trim().ToLowerInvariant()) {
        '^critical$' { 'crit'; break }
        '^high$' { 'high'; break }
        '^medium$|^moderate$' { 'med'; break }
        '^low$' { 'low'; break }
        default { 'info' }
    }
}

function Get-SeverityLabel([string]$Severity) {
    switch (Get-SeverityKey $Severity) {
        'crit' { 'Critical'; break }
        'high' { 'High'; break }
        'med' { 'Medium'; break }
        'low' { 'Low'; break }
        default { 'Info' }
    }
}

function Get-RuleKey($Finding) {
    if ($Finding.PSObject.Properties['RuleId'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.RuleId)) {
        return [string]$Finding.RuleId
    }
    $title = [string]$Finding.Title
    if ($title -match '^\s*([A-Za-z0-9._:-]+)\s*:') { return $Matches[1] }
    if ($Finding.PSObject.Properties['Id'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Id)) { return [string]$Finding.Id }
    return 'unkeyed-rule'
}

function Get-FrameworkNames($Finding) {
    $items = New-Object System.Collections.Generic.List[string]
    if ($Finding.PSObject.Properties['Frameworks'] -and $Finding.Frameworks) {
        foreach ($fw in @($Finding.Frameworks)) {
            $name = if ($fw -is [string]) { [string]$fw } elseif ($fw.PSObject.Properties['Name']) { [string]$fw.Name } elseif ($fw.PSObject.Properties['framework']) { [string]$fw.framework } elseif ($fw.PSObject.Properties['Kind']) { [string]$fw.Kind } else { [string]$fw }
            if (-not [string]::IsNullOrWhiteSpace($name)) { $items.Add($name.Trim()) }
        }
    }
    if ($items.Count -eq 0 -and $Finding.PSObject.Properties['Controls'] -and $Finding.Controls) {
        foreach ($ctrl in @($Finding.Controls)) {
            $name = [string]$ctrl
            if (-not [string]::IsNullOrWhiteSpace($name)) { $items.Add($name.Trim()) }
        }
    }
    return @($items | Select-Object -Unique)
}

function Get-Domain($Finding) {
    if ($Finding.PSObject.Properties['Pillar'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Pillar)) { return [string]$Finding.Pillar }
    if ($Finding.PSObject.Properties['Category'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Category)) { return [string]$Finding.Category }
    if ($Finding.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.Source)) { return [string]$Finding.Source }
    return 'Uncategorized'
}

function Get-SubscriptionId($Finding) {
    foreach ($p in @('SubscriptionId','subscriptionId')) {
        if ($Finding.PSObject.Properties[$p] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.$p)) { return [string]$Finding.$p }
    }
    $resourceId = if ($Finding.PSObject.Properties['ResourceId']) { [string]$Finding.ResourceId } else { '' }
    if ($resourceId -match '(?i)/subscriptions/([^/]+)') { return $Matches[1] }
    $entityId = if ($Finding.PSObject.Properties['EntityId']) { [string]$Finding.EntityId } else { '' }
    if ($entityId -match '(?i)^subscription:([0-9a-f-]+)$') { return $Matches[1] }
    return ''
}

function Get-ResourceGroup($Finding) {
    if ($Finding.PSObject.Properties['ResourceGroup'] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.ResourceGroup)) { return [string]$Finding.ResourceGroup }
    $resourceId = if ($Finding.PSObject.Properties['ResourceId']) { [string]$Finding.ResourceId } else { '' }
    if ($resourceId -match '(?i)/resourcegroups/([^/]+)') { return $Matches[1] }
    return ''
}

function Get-EntityLabel($Finding) {
    foreach ($p in @('EntityName','EntityId','ResourceId','Detail')) {
        if ($Finding.PSObject.Properties[$p] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.$p)) { return [string]$Finding.$p }
    }
    return '(unknown entity)'
}

function Get-StatusLabel($Finding) {
    if ($Finding.PSObject.Properties['Compliant'] -and $Finding.Compliant -eq $true) { return 'Pass' }
    $resultState = if ($Finding.PSObject.Properties['ResultState']) { [string]$Finding.ResultState } else { '' }
    if ($resultState -match '(?i)investigate|warning') { return 'Warning' }
    return 'Fail'
}

function Get-FrameworkClass([string]$Framework) {
    $u = ($Framework ?? '').Trim().ToUpperInvariant()
    if ($u.StartsWith('CIS')) { return 'fw-cis' }
    if ($u.StartsWith('NIST')) { return 'fw-nist' }
    if ($u.StartsWith('MITRE')) { return 'fw-mitre' }
    if ($u.StartsWith('EIDSCA')) { return 'fw-eidsca' }
    if ($u.StartsWith('EIDAS')) { return 'fw-eidas' }
    if ($u.StartsWith('SOC')) { return 'fw-soc' }
    if ($u.StartsWith('ISO')) { return 'fw-iso' }
    if ($u -eq 'MCSB') { return 'fw-mcsb' }
    if ($u -eq 'CAF') { return 'fw-caf' }
    if ($u -eq 'WAF') { return 'fw-waf' }
    if ($u.StartsWith('CISA')) { return 'fw-cisa' }
    if ($u.StartsWith('ORCA')) { return 'fw-orca' }
    return 'fw-default'
}

function Get-FrameworkBadgesHtml([string[]]$Frameworks) {
    $arr = @($Frameworks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($arr.Count -eq 0) { return '<span class="faint" style="font-size:11px">no framework mapping</span>' }
    return ($arr | ForEach-Object { "<span class='fw $(Get-FrameworkClass $_)' title='$(HE $_)'>$(HE $_)</span>" }) -join ''
}

$rawFindings = @(Get-Content $InputPath -Raw | ConvertFrom-Json -ErrorAction Stop)
if ($rawFindings.Count -eq 1 -and $rawFindings[0] -and $rawFindings[0].PSObject.Properties['Findings']) {
    $rawFindings = @($rawFindings[0].Findings)
}

$entities = @()
$entitiesPath = Join-Path (Split-Path $InputPath -Parent) 'entities.json'
if (Test-Path $entitiesPath) {
    try {
        $entityPayload = Get-Content $entitiesPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($entityPayload.PSObject.Properties['Entities']) { $entities = @($entityPayload.Entities) }
    } catch {
        Write-Warning (Remove-Credentials "Could not parse entities file: $_")
    }
}

$manifestPath = Join-Path $PSScriptRoot 'tools' 'tool-manifest.json'
$manifestTools = @()
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $manifestTools = @($manifest.tools)
    } catch {
        Write-Warning (Remove-Credentials "Could not parse tool-manifest.json: $_")
    }
}

$toolStatusMap = @{}
$toolStatusPath = Join-Path (Split-Path $InputPath -Parent) 'tool-status.json'
if (Test-Path $toolStatusPath) {
    try {
        foreach ($row in @(Get-Content $toolStatusPath -Raw | ConvertFrom-Json -ErrorAction Stop)) {
            if ($row.PSObject.Properties['Tool']) { $toolStatusMap[[string]$row.Tool] = [string]$row.Status }
        }
    } catch {
        Write-Warning (Remove-Credentials "Could not parse tool-status.json: $_")
    }
}

$toolLabels = @{}
$toolProvider = @{}
$toolScope = @{}
$toolReportColor = @{}
foreach ($t in $manifestTools) {
    $toolLabels[[string]$t.name] = if ($t.PSObject.Properties['displayName']) { [string]$t.displayName } else { [string]$t.name }
    $toolProvider[[string]$t.name] = if ($t.PSObject.Properties['provider']) { [string]$t.provider } else { 'unknown' }
    $toolScope[[string]$t.name] = if ($t.PSObject.Properties['scope']) { [string]$t.scope } else { 'unknown' }
    $reportColor = ''
    if ($t.PSObject.Properties['report'] -and $t.report -and $t.report.PSObject.Properties['color']) {
        $reportColor = [string]$t.report.color
    }
    $toolReportColor[[string]$t.name] = $reportColor
}

$normalized = foreach ($f in $rawFindings) {
    $source = if ($f.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$f.Source)) { [string]$f.Source } else { 'unknown' }
    $sevKey = Get-SeverityKey ([string]$f.Severity)
    $sevLabel = Get-SeverityLabel ([string]$f.Severity)
    $frameworks = @(Get-FrameworkNames $f)
    $status = Get-StatusLabel $f
    $ruleKey = Get-RuleKey $f
    $entityLabel = Get-EntityLabel $f
    [pscustomobject]@{
        Id = if ($f.PSObject.Properties['Id']) { [string]$f.Id } else { [guid]::NewGuid().ToString() }
        Source = $source
        SourceLabel = if ($toolLabels.ContainsKey($source)) { $toolLabels[$source] } else { $source }
        SeverityKey = $sevKey
        Severity = $sevLabel
        RuleKey = $ruleKey
        Title = if ($f.PSObject.Properties['Title']) { [string]$f.Title } else { $ruleKey }
        Entity = $entityLabel
        EntityType = if ($f.PSObject.Properties['EntityType']) { [string]$f.EntityType } else { '' }
        Subscription = Get-SubscriptionId $f
        ResourceGroup = Get-ResourceGroup $f
        Tool = $source
        Status = $status
        Frameworks = $frameworks
        Domain = Get-Domain $f
        Detail = if ($f.PSObject.Properties['Detail']) { [string]$f.Detail } else { '' }
        Remediation = if ($f.PSObject.Properties['Remediation']) { [string]$f.Remediation } else { '' }
        LearnMoreUrl = if ($f.PSObject.Properties['LearnMoreUrl']) { [string]$f.LearnMoreUrl } else { '' }
        Pillar = if ($f.PSObject.Properties['Pillar']) { [string]$f.Pillar } else { '' }
        Impact = if ($f.PSObject.Properties['Impact']) { [string]$f.Impact } else { '' }
        Effort = if ($f.PSObject.Properties['Effort']) { [string]$f.Effort } else { '' }
        DeepLinkUrl = if ($f.PSObject.Properties['DeepLinkUrl']) { [string]$f.DeepLinkUrl } else { '' }
        RemediationSnippets = if ($f.PSObject.Properties['RemediationSnippets']) { @($f.RemediationSnippets) } else { @() }
        EvidenceUris = if ($f.PSObject.Properties['EvidenceUris']) { @($f.EvidenceUris) } else { @() }
        MitreTactics = if ($f.PSObject.Properties['MitreTactics']) { @($f.MitreTactics) } else { @() }
        MitreTechniques = if ($f.PSObject.Properties['MitreTechniques']) { @($f.MitreTechniques) } else { @() }
        BaselineTags = if ($f.PSObject.Properties['BaselineTags']) { @($f.BaselineTags) } else { @() }
        EntityRefs = if ($f.PSObject.Properties['EntityRefs']) { @($f.EntityRefs) } else { @() }
        ScoreDelta = if ($f.PSObject.Properties['ScoreDelta']) { $f.ScoreDelta } else { $null }
        ToolVersion = if ($f.PSObject.Properties['ToolVersion']) { [string]$f.ToolVersion } else { '' }
    }
}

$total = @($normalized).Count
$nonPass = @($normalized | Where-Object { $_.Status -ne 'Pass' })
$sevOrder = @('crit','high','med','low','info')
$sevLabels = @{ crit='Crit'; high='High'; med='Med'; low='Low'; info='Info' }
$sevFull = @{ crit='Critical'; high='High'; med='Medium'; low='Low'; info='Info' }
$sevCount = @{}
foreach ($k in $sevOrder) { $sevCount[$k] = @($nonPass | Where-Object { $_.SeverityKey -eq $k }).Count }

$compliantCount = @($normalized | Where-Object { $_.Status -eq 'Pass' }).Count
$compliantPct = if ($total -gt 0) { [math]::Round(($compliantCount / $total) * 100) } else { 100 }
$toolsWithFindings = @($normalized | Select-Object -ExpandProperty Tool -Unique)
$entityCount = if ($entities.Count -gt 0) { $entities.Count } else { @($normalized | Select-Object -ExpandProperty Entity -Unique).Count }
$posture = if ($compliantPct -ge 90) { 'A' } elseif ($compliantPct -ge 75) { 'B' } elseif ($compliantPct -ge 60) { 'C' } else { 'D' }

$providerLabel = @{ azure='Azure'; microsoft365='Microsoft 365'; graph='Microsoft Graph'; github='GitHub'; ado='Azure DevOps'; cli='CLI / local'; unknown='Other' }
$coverageGroups = @{}
foreach ($tool in $manifestTools) {
    $provider = if ($tool.PSObject.Properties['provider']) { [string]$tool.provider } else { 'unknown' }
    $scope = if ($tool.PSObject.Properties['scope']) { [string]$tool.scope } else { 'unknown' }
    $key = "$provider||$scope"
    if (-not $coverageGroups.ContainsKey($key)) {
        $coverageGroups[$key] = [pscustomobject]@{ Provider=$provider; Scope=$scope; Tools=New-Object System.Collections.Generic.List[object] }
    }
    $id = [string]$tool.name
    $rows = @($normalized | Where-Object { $_.Tool -eq $id })
    $status = if ($toolStatusMap.ContainsKey($id)) { [string]$toolStatusMap[$id] } elseif ($rows.Count -gt 0) { 'Success' } else { 'Skipped' }
    $disabled = ($tool.PSObject.Properties['enabled'] -and -not $tool.enabled) -or ($status -ne 'Success')
    $failRows = @($rows | Where-Object { $_.Status -ne 'Pass' })
    $passPct = if ($rows.Count -gt 0) { [math]::Round((($rows.Count - $failRows.Count) / $rows.Count) * 100) } else { 0 }
    $counts = @{ crit=0; high=0; med=0; low=0; info=0 }
    foreach ($row in $failRows) { $counts[$row.SeverityKey]++ }
    $displayName = if ($tool.PSObject.Properties['displayName']) { [string]$tool.displayName } else { $id }
    $coverageGroups[$key].Tools.Add([pscustomobject]@{
        Id=$id
        Name=$displayName
        Scope=$scope
        Disabled=$disabled
        PassPct=$passPct
        Total=$rows.Count
        Counts=$counts
        Status=$status
    })
}

# Heatmap matrices
$subs = @($normalized | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Subscription) } | Select-Object -ExpandProperty Subscription -Unique | Sort-Object)
$domains = @($normalized | Select-Object -ExpandProperty Domain -Unique | Sort-Object)
if ($domains.Count -eq 0) { $domains = @('Uncategorized') }
$toolsForRows = @($manifestTools | ForEach-Object { [string]$_.name })
$fwRows = @($normalized | ForEach-Object { @($_.Frameworks) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Sort-Object)
$rgRows = @($normalized | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ResourceGroup) } | Select-Object -ExpandProperty ResourceGroup -Unique | Sort-Object)
if ($rgRows.Count -eq 0) { $rgRows = @('n/a') }

$hmMatrices = @{}

$domainCells = @{}
foreach ($d in $domains) {
    foreach ($s in $subs) {
        $k = "$d||$s"
        $domainCells[$k] = @($normalized | Where-Object { $_.Domain -eq $d -and $_.Subscription -eq $s -and $_.Status -ne 'Pass' }).Count
    }
}
$hmMatrices['domain'] = [pscustomobject]@{ rowLabel='Control domain'; rows=$domains; cols=$subs; cells=$domainCells }

$toolSevCells = @{}
foreach ($toolId in $toolsForRows) {
    foreach ($sev in $sevOrder) {
        $k = "$toolId||$sev"
        $toolSevCells[$k] = @($normalized | Where-Object { $_.Tool -eq $toolId -and $_.SeverityKey -eq $sev -and $_.Status -ne 'Pass' }).Count
    }
}
$hmMatrices['toolsev'] = [pscustomobject]@{ rowLabel='Tool'; rows=$toolsForRows; cols=$sevOrder; cells=$toolSevCells }

$fwCells = @{}
foreach ($fw in $fwRows) {
    foreach ($s in $subs) {
        $k = "$fw||$s"
        $fwCells[$k] = @($normalized | Where-Object { $_.Subscription -eq $s -and $_.Status -ne 'Pass' -and ($_.Frameworks -contains $fw) }).Count
    }
}
$hmMatrices['fwsub'] = [pscustomobject]@{ rowLabel='Framework'; rows=$fwRows; cols=$subs; cells=$fwCells }

$defaultHmMode = if ($subs.Count -gt 0) { 'domain' } else { 'toolsev' }
# Fallback is required by issue #295: when no subscription dimension exists, render Tool x Severity instead of Domain x Subscription.

# Top risks
$sevWeight = @{ crit=10; high=5; med=2; low=1; info=0 }
$riskGroups = @($nonPass | Group-Object -Property RuleKey)
$topRisks = @(
    $riskGroups | ForEach-Object {
        $grp = @($_.Group)
        $highest = @($grp | Sort-Object @{Expression={ $sevWeight[$_.SeverityKey] };Descending=$true})[0]
        $entityCountForRule = @($grp | Select-Object -ExpandProperty Entity -Unique).Count
        [pscustomobject]@{
            RuleKey = $_.Name
            Title = $highest.Title
            SeverityKey = $highest.SeverityKey
            Severity = $highest.Severity
            Domain = $highest.Domain
            Tool = $highest.Tool
            ToolLabel = $highest.SourceLabel
            Count = $grp.Count
            ImpactScore = ([int]$sevWeight[$highest.SeverityKey]) * [math]::Max(1, $entityCountForRule)
            Frameworks = @($grp | ForEach-Object { @($_.Frameworks) } | Select-Object -Unique)
        }
    } | Sort-Object @{Expression='ImpactScore';Descending=$true}, @{Expression='Count';Descending=$true}, @{Expression='RuleKey';Descending=$false} | Select-Object -First 10
)

$topRecommendationLimit = [math]::Max(1, $TopRecommendationsCount)
$topRecs = @($topRisks | Select-Object -First $topRecommendationLimit)

$pillarSummary = @(
    $nonPass | Group-Object -Property Domain | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{
            Pillar = [string]$_.Name
            Count = [int]$_.Count
        }
    }
)
$pillarSummary = @($pillarSummary | Select-Object -First 8)
$maxPillarCount = 1
foreach ($pillar in $pillarSummary) {
    if ($pillar.Count -gt $maxPillarCount) { $maxPillarCount = [int]$pillar.Count }
}
$pillarSummaryHtml = if ($pillarSummary.Count -eq 0) {
    "<div class='faint'>No non-pass findings to summarize by pillar.</div>"
} else {
    ($pillarSummary | ForEach-Object {
        $pct = [math]::Round(($_.Count / $maxPillarCount) * 100)
        "<div class='pill-row'><span class='pill-name'>$(HE $_.Pillar)</span><div class='pill-track'><i style='width:${pct}%'></i></div><span class='pill-count'>$($_.Count)</span></div>"
    }) -join "`n"
}

# Findings rows (server-rendered)
$findingRows = New-Object System.Collections.Generic.List[string]
foreach ($row in $normalized) {
    $rowId = HE $row.Id
    $frameworkBadges = Get-FrameworkBadgesHtml $row.Frameworks
    $statusClass = if ($row.Status -eq 'Pass') { 'sev-pass' } elseif ($row.Status -eq 'Warning') { 'sev-med' } else { 'sev-high' }
    $evidenceUris = @($row.EvidenceUris)
    $remediationSnippets = @($row.RemediationSnippets)
    $mitreTactics = @($row.MitreTactics)
    $mitreTechniques = @($row.MitreTechniques)
    $baselineTags = @($row.BaselineTags)
    $entityRefs = @($row.EntityRefs)

    $evidenceLinks = if ($evidenceUris.Count -gt 0) {
        ($evidenceUris | Where-Object { $_ } | ForEach-Object { "<a href='$(HE $_)' target='_blank' rel='noopener noreferrer'>Evidence link</a>" }) -join ''
    } else { '' }

    $snippetHtml = if ($remediationSnippets.Count -gt 0) {
        ($remediationSnippets | Where-Object { $null -ne $_ } | ForEach-Object {
            $snippet = $_
            $name = if ($snippet.PSObject.Properties.Match('Name').Count -gt 0) {
                [string]$snippet.Name
            } elseif ($snippet.PSObject.Properties.Match('Title').Count -gt 0) {
                [string]$snippet.Title
            } elseif ($snippet.PSObject.Properties.Match('language').Count -gt 0) {
                "Snippet ($([string]$snippet.language))"
            } elseif ($snippet.PSObject.Properties.Match('Language').Count -gt 0) {
                "Snippet ($([string]$snippet.Language))"
            } else {
                'Snippet'
            }

            $code = ''
            if ($snippet.PSObject.Properties.Match('Snippet').Count -gt 0) {
                $code = [string]$snippet.Snippet
            } elseif ($snippet.PSObject.Properties.Match('Code').Count -gt 0) {
                $code = [string]$snippet.Code
            } elseif ($snippet.PSObject.Properties.Match('code').Count -gt 0) {
                $code = [string]$snippet.code
            } elseif ($snippet.PSObject.Properties.Match('before').Count -gt 0 -or $snippet.PSObject.Properties.Match('after').Count -gt 0) {
                $before = if ($snippet.PSObject.Properties.Match('before').Count -gt 0) { [string]$snippet.before } else { '' }
                $after = if ($snippet.PSObject.Properties.Match('after').Count -gt 0) { [string]$snippet.after } else { '' }
                $code = "Before:`n$before`n`nAfter:`n$after"
            } else {
                $code = [string]$snippet
            }

            "<details style='margin-top:8px'><summary>$(HE $name)</summary><pre>$(HE $code)</pre></details>"
        }) -join ''
    } else { '' }

    $mitreHtml = ''
    if ($mitreTactics.Count -gt 0 -or $mitreTechniques.Count -gt 0) {
        $mitreHtml = "<h4 style='margin-top:10px'>MITRE</h4><p>Tactics: $(HE ($mitreTactics -join ', '))<br>Techniques: $(HE ($mitreTechniques -join ', '))</p>"
    }

    $baselineHtml = ''
    if ($baselineTags.Count -gt 0) {
        $baselineHtml = "<h4 style='margin-top:10px'>Baseline tags</h4><p>$(HE ($baselineTags -join ', '))</p>"
    }

    $entityRefsHtml = ''
    if ($entityRefs.Count -gt 0) {
        $entityRefsHtml = "<h4 style='margin-top:10px'>Entity refs</h4><pre>$(HE ($entityRefs -join [Environment]::NewLine))</pre>"
    }

    $impactEffort = ''
    if (-not [string]::IsNullOrWhiteSpace($row.Impact) -or -not [string]::IsNullOrWhiteSpace($row.Effort)) {
        $scoreDeltaText = if ($null -ne $row.ScoreDelta -and [string]$row.ScoreDelta -ne '') { "<br>Score delta: $(HE $row.ScoreDelta)" } else { '' }
        $impactEffort = "<h4 style='margin-top:10px'>Impact and effort</h4><p>Impact: $(HE $row.Impact)<br>Effort: $(HE $row.Effort)$scoreDeltaText</p>"
    }

    $toolChipStyle = ''
    if ($toolReportColor.ContainsKey($row.Tool) -and -not [string]::IsNullOrWhiteSpace([string]$toolReportColor[$row.Tool])) {
        $color = [string]$toolReportColor[$row.Tool]
        $toolChipStyle = " style='background:$color;border-color:$color;color:#fff'"
    }

    $links = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($row.LearnMoreUrl)) { $links.Add("<a href='$(HE $row.LearnMoreUrl)' target='_blank' rel='noopener noreferrer'>Learn more</a>") }
    if (-not [string]::IsNullOrWhiteSpace($row.DeepLinkUrl)) { $links.Add("<a href='$(HE $row.DeepLinkUrl)' target='_blank' rel='noopener noreferrer'>Open deep link</a>") }
    if ($links.Count -eq 0) { $links.Add("<span class='tool-chip'>No links provided</span>") }

    $findingRows.Add(@"
<tr class='row s-$($row.SeverityKey)' data-id='$rowId' data-severity='$($row.SeverityKey)' data-rule='$(HE $row.RuleKey)' data-entity='$(HE $row.Entity)' data-sub='$(HE $row.Subscription)' data-tool='$(HE $row.Tool)' data-status='$(HE $row.Status)'>
  <td><span class='pill sev-$($row.SeverityKey)'>$(HE $row.Severity)</span></td>
  <td><div style='font-weight:600'><span class='rule-id'>$(HE $row.RuleKey)</span>$(HE $row.Title)</div><div style='font-size:11.5px;margin-top:3px'>$frameworkBadges <span class='faint' style='margin-left:6px'>$(HE $row.Domain)</span></div></td>
  <td><div class='mono' style='font-size:12px'>$(HE $row.Entity)</div><div class='faint' style='font-size:11px'>$(HE $row.EntityType) · $(HE $row.ResourceGroup)</div></td>
  <td>$(HE $row.Subscription)</td>
  <td><span class='tool-chip'$toolChipStyle>$(HE $row.SourceLabel)</span></td>
  <td><span class='pill $statusClass'>$(HE $row.Status)</span></td>
</tr>
<tr class='expand' data-parent-id='$rowId' hidden>
  <td colspan='6'><div class='ev-grid'>
    <div class='ev'>
      <h4>Description</h4>
      <p>$(HE $row.Detail)</p>
      <h4 style='margin-top:10px'>Evidence</h4>
      <pre>$(HE $row.Detail)</pre>
      <div class='links'>$evidenceLinks</div>
      $mitreHtml
      $baselineHtml
    </div>
    <div class='ev'>
      <h4>Remediation</h4>
      <p>$(HE $row.Remediation)</p>
      $impactEffort
      $snippetHtml
      $entityRefsHtml
      <div class='links'>$($links -join '')</div>
    </div>
  </div></td>
</tr>
"@)
}

# Coverage markup
$coverageHtml = New-Object System.Collections.Generic.List[string]
$orderedCoverageGroups = @($coverageGroups.Values | Sort-Object Provider, Scope)
foreach ($group in $orderedCoverageGroups) {
    $tiles = foreach ($tile in @($group.Tools | Sort-Object Name)) {
        $stack = ($sevOrder | ForEach-Object {
            $w = if ($tile.Total -gt 0) { [math]::Round(($tile.Counts[$_] / [math]::Max(1, $tile.Total)) * 100) } else { 0 }
            if ($w -gt 0) { "<i style='width:${w}%;background:var(--$_)' title='$($tile.Counts[$_]) $($sevFull[$_])'></i>" }
        }) -join ''
        if (-not $stack) { $stack = "<i style='width:100%;background:var(--surface-2)'></i>" }
        $toolClass = if ($tile.Disabled) { 'disabled' } else { '' }
        @"
<div class='tool $toolClass'>
  <div class='top'>
    <div class='ico'>●</div>
    <div class='name'>$(HE $tile.Name)</div>
    <span class='scope'>$(HE $tile.Scope)</span>
  </div>
  <div class='pass'><span>$($tile.PassPct)% pass</span><div class='bar'><i style='width:$($tile.PassPct)%'></i></div></div>
  <div class='stack'>$stack</div>
  <div class='meta'><span>$($tile.Total) findings</span><span class='mono'>$(HE $tile.Id)</span></div>
</div>
"@
    }

    $provider = if ($providerLabel.ContainsKey($group.Provider)) { $providerLabel[$group.Provider] } else { $group.Provider }
    $toolCountInGroup = if ($group.Tools) { [int]$group.Tools.Count } else { 0 }
    $tilesHtml = ($tiles -join "`n")
    $coverageHtml.Add(@"
<div class='cov-group'>
  <div class='cov-group-h' onclick='this.parentNode.classList.toggle("collapsed")'>
    <span class='chev'>▾</span>
    <h3>$(HE $provider) · $(HE $group.Scope)</h3>
    <span class='cnt'>$toolCountInGroup tools</span>
  </div>
  <div class='cov-grid'>
$tilesHtml
  </div>
</div>
"@)
}

# Heatmap data JSON for client renderer
$hmModel = [pscustomobject]@{
    defaultMode = $defaultHmMode
    hasSubscriptions = ($subs.Count -gt 0)
    matrices = $hmMatrices
    toolLabels = $toolLabels
    severityLabels = $sevFull
}
$hmJson = ($hmModel | ConvertTo-Json -Depth 20 -Compress) -replace '</','<\/'

$riskRowsHtml = if ($topRisks.Count -eq 0) {
    "<div class='risk'><div class='ttl'>No risk items in this run.</div><div class='meta'>Add findings to populate this panel.</div><div></div><div class='count'><strong>0</strong>findings</div></div>"
} else {
    ($topRisks | ForEach-Object {
        $fw = Get-FrameworkBadgesHtml $_.Frameworks
        @"
<div class='risk'>
  <span class='pill sev-$($_.SeverityKey)'>$(HE $_.Severity)</span>
  <div>
    <div class='ttl'><a href='#findings' onclick='focusRisk("$(HE $_.RuleKey)");return false;'>$(HE $_.Title)</a></div>
    <div class='meta'>$(HE $_.Domain) · $fw</div>
  </div>
  <span class='tool-tag'>$(HE $_.ToolLabel)</span>
  <div class='count'><strong>$([int]$_.Count)</strong>findings</div>
</div>
"@
    }) -join "`n"
}

$topRecsHtml = if ($topRecs.Count -eq 0) {
    "<div class='rec'><span class='pill ghost'>none</span><div class='body'><span class='ttl'>No recommendations yet</span><div class='meta'>Run completed without non-pass findings.</div></div><div class='impact'><strong>0</strong>impact</div></div>"
} else {
    ($topRecs | ForEach-Object {
        @"
<div class='rec'>
  <span class='pill sev-$($_.SeverityKey)'>$(HE $_.Severity)</span>
  <div class='body'><span class='ttl'><a href='#findings' onclick='focusRisk("$(HE $_.RuleKey)");return false;'>$(HE $_.Title)</a></span><div class='meta'>$([int]$_.Count) findings · $(HE $_.Domain)</div></div>
  <div class='impact'><strong>$([int]$_.ImpactScore)</strong>impact</div>
</div>
"@
    }) -join "`n"
}

$entityTypeCounts = @{}
if ($entities.Count -gt 0) {
    foreach ($e in $entities) {
        $t = if ($e.PSObject.Properties['EntityType']) { [string]$e.EntityType } else { 'Unknown' }
        if (-not $entityTypeCounts.ContainsKey($t)) { $entityTypeCounts[$t] = 0 }
        $entityTypeCounts[$t]++
    }
} else {
    foreach ($row in $normalized) {
        $t = if (-not [string]::IsNullOrWhiteSpace($row.EntityType)) { $row.EntityType } else { 'Unknown' }
        if (-not $entityTypeCounts.ContainsKey($t)) { $entityTypeCounts[$t] = 0 }
        $entityTypeCounts[$t]++
    }
}
if ($entityTypeCounts.Count -eq 0) { $entityTypeCounts['Unknown'] = 0 }
$maxEntity = [math]::Max(1, [int](@($entityTypeCounts.Values | Measure-Object -Maximum).Maximum))
$entityBarsHtml = ($entityTypeCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    $pct = [math]::Round(($_.Value / $maxEntity) * 100)
    "<div class='ent-bar'><span class='lab'>$(HE $_.Key)</span><div class='track'><div class='fill' style='width:${pct}%'></div></div><span class='n'>$($_.Value)</span></div>"
}) -join "`n"

$toolVersionRows = @($normalized | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ToolVersion) } | Group-Object -Property Tool | ForEach-Object {
    $first = @($_.Group)[0]
    "<tr><td>$(HE $first.SourceLabel)</td><td>$(HE $first.ToolVersion)</td></tr>"
})
if ($toolVersionRows.Count -eq 0) {
    $toolVersionRows = @('<tr><td>n/a</td><td>No tool versions in this run</td></tr>')
}

$trendHtml = if (@($Trend).Count -ge 2) {
    $perSeverity = @{}
    foreach ($sev in $sevOrder) {
        $vals = @($Trend | ForEach-Object {
            $bucket = if ($_.PSObject.Properties['BySeverity']) { $_.BySeverity } else { $null }
            if ($null -eq $bucket) { 0 } else {
                $name = $sevFull[$sev]
                if ($bucket.PSObject.Properties[$name]) { [int]$bucket.$name } elseif ($bucket.PSObject.Properties[($name.ToLowerInvariant())]) { [int]$bucket.($name.ToLowerInvariant()) } else { 0 }
            }
        })
        $maxVal = [math]::Max(1, [int](@($vals | Measure-Object -Maximum).Maximum))
        $points = for ($i=0; $i -lt $vals.Count; $i++) {
            $x = if ($vals.Count -gt 1) { [math]::Round(($i / ($vals.Count - 1)) * 100, 2) } else { 0 }
            $y = [math]::Round(30 - (($vals[$i] / $maxVal) * 26), 2)
            "$x,$y"
        }
        $delta = [int]$vals[-1] - [int]$vals[-2]
        $deltaText = if ($delta -gt 0) { "▲ $delta" } elseif ($delta -lt 0) { "▼ $([math]::Abs($delta))" } else { 'flat' }
        $deltaClass = if ($delta -gt 0) { 'sev-text-high' } elseif ($delta -lt 0) { 'sev-text-low' } else { 'faint' }
        $perSeverity[$sev] = @"
<div class='trend'><div class='lab'>$($sevFull[$sev])</div><div class='val sev-text-$sev'>$([int]$vals[-1])</div><div class='delta $deltaClass'>$deltaText</div><svg viewBox='0 0 100 32'><polyline fill='none' stroke='var(--$sev)' stroke-width='1.8' points='$($points -join ' ')'/></svg></div>
"@
    }
    "<div class='trend-strip' aria-label='run trend by severity'>$($sevOrder | ForEach-Object { $perSeverity[$_] } | Out-String)</div>"
} else {
    "<div class='trend-strip'><div class='trend' style='grid-column:1 / -1'><div class='lab'>Trend</div><div class='val'>n/a</div><div class='delta faint'>trend coming after 2nd run</div></div></div>"
}

$date = Get-Date -Format 'yyyy-MM-dd HH:mm UTC'

$html = @"
<!DOCTYPE html>
<html lang='en' data-theme='light'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Azure Analyzer - Posture Report</title>
<style>
:root{
  --bg:#f7f8fa;--surface:#ffffff;--surface-2:#f1f3f6;--border:#e3e6eb;--border-strong:#cdd2da;
  --text:#0f172a;--text-muted:#475569;--text-faint:#64748b;
  --brand:#0b5fff;--brand-ink:#003fb3;--accent:#0ea5e9;
  --crit:#7f1d1d;--high:#b91c1c;--med:#b45309;--low:#a16207;--info:#475569;
  --crit-bg:#fef2f2;--high-bg:#fee2e2;--med-bg:#fef3c7;--low-bg:#fefce8;--info-bg:#f1f5f9;
  --pass:#15803d;--pass-bg:#dcfce7;
  --shadow-sm:0 1px 2px rgba(15,23,42,.06),0 1px 1px rgba(15,23,42,.04);
  --shadow:0 4px 12px rgba(15,23,42,.08),0 2px 4px rgba(15,23,42,.04);
  --radius:10px;--radius-sm:6px;--radius-lg:14px;
  --font:-apple-system,BlinkMacSystemFont,"Segoe UI Variable","Segoe UI",Inter,system-ui,sans-serif;
  --mono:ui-monospace,"Cascadia Code","JetBrains Mono",Consolas,monospace;
}
[data-theme='dark']{
  --bg:#0b1220;--surface:#111a2e;--surface-2:#172238;--border:#243049;--border-strong:#324264;
  --text:#e8edf6;--text-muted:#9aa7bf;--text-faint:#7a8aa6;
  --brand:#3b82f6;--brand-ink:#60a5fa;--accent:#22d3ee;
  --crit:#f87171;--high:#fb923c;--med:#fbbf24;--low:#facc15;--info:#94a3b8;
  --crit-bg:#3a1212;--high-bg:#3a1f10;--med-bg:#3a2a0a;--low-bg:#332a0a;--info-bg:#1e293b;
  --pass:#4ade80;--pass-bg:#0f2a1a;
}
*,*::before,*::after{box-sizing:border-box} html,body{margin:0;padding:0}
body{font-family:var(--font);font-size:14px;line-height:1.5;color:var(--text);background:var(--bg);-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
a{color:var(--brand);text-decoration:none}a:hover{text-decoration:underline}
button{font:inherit;color:inherit;cursor:pointer;background:none;border:0}
h1,h2,h3,h4{margin:0;font-weight:600;letter-spacing:-.01em} h1{font-size:18px}h2{font-size:16px}h3{font-size:14px}
code,kbd{font-family:var(--mono);font-size:12.5px}
.muted{color:var(--text-muted)}.faint{color:var(--text-faint)}.mono{font-family:var(--mono)}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:600;line-height:1.4;border:1px solid transparent;white-space:nowrap}
.pill.ghost{background:var(--surface-2);color:var(--text-muted);border-color:var(--border)}
.sev-crit{background:var(--crit);color:#fff}.sev-high{background:var(--high);color:#fff}.sev-med{background:var(--med);color:#fff}.sev-low{background:var(--low);color:#fff}.sev-info{background:var(--info);color:#fff}.sev-pass{background:var(--pass);color:#fff}
.sev-text-crit{color:var(--crit)}.sev-text-high{color:var(--high)}.sev-text-med{color:var(--med)}.sev-text-low{color:var(--low)}.sev-text-info{color:var(--info)}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow-sm)} .card-pad{padding:18px}
.section{padding:28px 32px;max-width:1440px;margin:0 auto}.section h2{display:flex;align-items:center;gap:10px;margin-bottom:14px}
.section h2 .badge{font-size:11px;font-weight:600;color:var(--text-faint);background:var(--surface-2);padding:2px 8px;border-radius:999px;border:1px solid var(--border)}
header.app{position:sticky;top:0;z-index:50;background:var(--surface);border-bottom:1px solid var(--border);box-shadow:var(--shadow-sm)}
.hdr-row{display:flex;align-items:center;gap:18px;padding:12px 32px;max-width:1440px;margin:0 auto;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:15px}
.tenant{display:flex;align-items:center;gap:6px;padding:4px 10px;border:1px solid var(--border);border-radius:999px;font-size:12.5px;color:var(--text-muted);background:var(--surface-2)} .tenant strong{color:var(--text)}
.kpis{display:flex;gap:8px;flex-wrap:wrap}.kpi{display:flex;align-items:center;gap:6px;padding:5px 10px;background:var(--surface-2);border:1px solid var(--border);border-radius:8px;font-size:12.5px;color:var(--text-muted)}.kpi strong{color:var(--text);font-weight:600}
.score{display:flex;align-items:center;gap:10px;padding:6px 12px 6px 6px;background:var(--surface-2);border:1px solid var(--border);border-radius:999px}
.score-text{display:flex;flex-direction:column;line-height:1.15}.score-text .num{font-weight:700;font-size:15px}.score-text .lbl{font-size:11px;color:var(--text-faint);text-transform:uppercase;letter-spacing:.05em}
.sev-strip{display:flex;gap:6px}.sev-cnt{display:flex;flex-direction:column;align-items:center;justify-content:center;min-width:54px;padding:6px 10px;border-radius:8px;color:#fff;font-weight:600}
.sev-cnt .n{font-size:16px;line-height:1}.sev-cnt .l{font-size:10px;text-transform:uppercase;letter-spacing:.06em;margin-top:3px;opacity:.95}
.theme-btn{display:inline-flex;align-items:center;justify-content:center;width:34px;height:34px;border:1px solid var(--border);border-radius:8px;background:var(--surface-2);color:var(--text-muted)}
nav.sub{position:sticky;top:62px;z-index:40;background:var(--surface);border-bottom:1px solid var(--border)} .sub-row{display:flex;gap:4px;padding:6px 32px;max-width:1440px;margin:0 auto;overflow-x:auto}
.sub-row a{padding:8px 12px;border-radius:6px;color:var(--text-muted);font-weight:500;font-size:13px;white-space:nowrap}.sub-row a.active{background:var(--surface-2);color:var(--text)}
.over-grid{display:grid;grid-template-columns:1.4fr 1fr;gap:18px}@media(max-width:1024px){.over-grid{grid-template-columns:1fr}}
.exec p{margin:0 0 10px;color:var(--text-muted);max-width:65ch}
.trend-strip{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-top:14px}.trend{padding:10px 12px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--surface);position:relative;overflow:hidden}
.trend .lab{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--text-faint);font-weight:600}.trend .val{font-size:20px;font-weight:700;margin-top:2px}.trend .delta{font-size:11px;font-weight:600;margin-top:2px}.trend svg{width:100%;height:32px;margin-top:6px;display:block}
.pillars{margin-top:14px;display:flex;flex-direction:column;gap:6px}.pill-row{display:grid;grid-template-columns:220px 1fr 44px;align-items:center;gap:8px}.pill-name{font-size:12px;color:var(--text-muted)}.pill-track{height:8px;border-radius:999px;background:var(--surface-2);overflow:hidden;border:1px solid var(--border)}.pill-track i{display:block;height:100%;background:var(--brand)}.pill-count{font-size:12px;text-align:right;color:var(--text);font-weight:600}
.recs{display:flex;flex-direction:column;gap:8px}.rec{display:grid;grid-template-columns:auto 1fr auto;gap:10px;align-items:center;padding:10px 12px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--surface)}
.rec .ttl{font-weight:600;font-size:13.5px;display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.rec .meta{font-size:12px;color:var(--text-faint);margin-top:2px}.rec .impact{font-size:11px;color:var(--text-faint);text-align:right}.rec .impact strong{display:block;font-size:14px;color:var(--text)}
.cov-group{margin-bottom:18px}.cov-group-h{display:flex;align-items:center;gap:10px;padding:10px 14px;background:var(--surface-2);border:1px solid var(--border);border-radius:var(--radius-sm);cursor:pointer;user-select:none}
.cov-group.collapsed .cov-grid{display:none}.cov-group-h .cnt{margin-left:auto;font-size:12px;color:var(--text-faint)}
.cov-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:10px;margin-top:10px}
.tool{padding:12px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--surface);display:flex;flex-direction:column;gap:8px}
.tool .top{display:flex;align-items:center;gap:8px}.tool .ico{width:28px;height:28px;border-radius:6px;display:flex;align-items:center;justify-content:center;background:var(--surface-2);color:var(--text-muted);flex-shrink:0}
.tool .name{font-weight:600;font-size:13px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.tool .scope{font-size:10.5px;text-transform:uppercase;letter-spacing:.05em;color:var(--text-faint);background:var(--surface-2);padding:2px 6px;border-radius:4px;border:1px solid var(--border)}
.tool .pass{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--text-muted)}.tool .bar{flex:1;height:6px;background:var(--surface-2);border-radius:3px;overflow:hidden}.tool .bar>i{display:block;height:100%;background:var(--pass);border-radius:3px}
.tool .stack{display:flex;height:5px;border-radius:3px;overflow:hidden;background:var(--surface-2)}.tool .stack>i{display:block;height:100%}.tool .meta{display:flex;justify-content:space-between;font-size:11.5px;color:var(--text-faint)}.tool.disabled{opacity:.55}
.hm-wrap{padding:18px}.hm-toggle{display:inline-flex;background:var(--surface-2);border:1px solid var(--border);border-radius:8px;padding:3px;gap:2px;margin-bottom:14px}.hm-toggle button{padding:6px 12px;font-size:12.5px;border-radius:6px;color:var(--text-muted);font-weight:500}.hm-toggle button.on{background:var(--surface);color:var(--text);box-shadow:var(--shadow-sm)}
.hm-table{width:100%;border-collapse:separate;border-spacing:3px}.hm-table th{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--text-faint);padding:6px;text-align:left;white-space:nowrap}.hm-table thead th{text-align:center}
.hm-table td.row-h{font-size:12px;color:var(--text-muted);padding:6px 10px 6px 6px;white-space:nowrap}
.hm-cell{position:relative;padding:0;border-radius:6px;height:38px;text-align:center;font-size:12px;font-weight:600;color:#fff;border:1px solid transparent}.hm-cell.empty{background:var(--surface-2);color:var(--text-faint)}
.hm-legend{display:flex;align-items:center;gap:8px;margin-top:14px;font-size:12px;color:var(--text-faint)}.hm-legend .grad{width:160px;height:10px;border-radius:5px;background:linear-gradient(90deg,var(--surface-2),var(--low),var(--med),var(--high),var(--crit))}
.risks{display:flex;flex-direction:column;gap:6px}.risk{display:grid;grid-template-columns:auto 1fr auto auto;gap:14px;align-items:center;padding:12px 14px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--surface)}
.risk .ttl{font-weight:600;font-size:13.5px}.risk .meta{font-size:12px;color:var(--text-faint);margin-top:2px}.risk .count{text-align:right;font-size:11px;color:var(--text-faint)}.risk .count strong{display:block;font-size:15px;color:var(--text);font-weight:700}.risk .tool-tag{font-size:11px;color:var(--text-muted);font-family:var(--mono);padding:3px 7px;border-radius:4px;background:var(--surface-2);border:1px solid var(--border)}
.fnd-toolbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;padding:14px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--surface);margin-bottom:12px}
.fnd-toolbar input[type=search],.fnd-toolbar select{font:inherit;font-size:13px;padding:6px 10px;border:1px solid var(--border);border-radius:6px;background:var(--surface);color:var(--text);min-width:160px}
.fnd-toolbar input[type=search]{flex:1;min-width:240px}
.sev-filter{display:flex;gap:4px;background:var(--surface-2);padding:3px;border-radius:8px;border:1px solid var(--border)}
.sev-filter button{padding:4px 9px;border-radius:5px;font-size:12px;font-weight:600;color:var(--text-muted)}.sev-filter button.on{background:var(--surface);color:var(--text);box-shadow:var(--shadow-sm)}
.fnd-table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden}
.fnd-table th{background:var(--surface-2);font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--text-faint);padding:9px 12px;text-align:left;cursor:pointer;user-select:none;border-bottom:1px solid var(--border);font-weight:600;white-space:nowrap}
.fnd-table td{padding:10px 12px;font-size:13px;border-bottom:1px solid var(--border);vertical-align:top}
.fnd-table tr.row{cursor:pointer}.fnd-table tr.row:hover td{background:var(--surface-2)}
.fnd-table tr.row td:first-child{border-left:3px solid var(--border-strong)}.fnd-table tr.row.s-crit td:first-child{border-left-color:var(--crit)}.fnd-table tr.row.s-high td:first-child{border-left-color:var(--high)}.fnd-table tr.row.s-med td:first-child{border-left-color:var(--med)}.fnd-table tr.row.s-low td:first-child{border-left-color:var(--low)}.fnd-table tr.row.s-info td:first-child{border-left-color:var(--info)}
.fnd-table tr.expand td{background:var(--surface-2);padding:14px 18px}.fnd-table tr.expand .ev-grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}.fnd-table tr.expand .ev h4{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--text-faint);margin:0 0 4px}.fnd-table tr.expand .ev pre{margin:0;padding:10px;background:var(--surface);border:1px solid var(--border);border-radius:6px;font-size:12px;overflow-x:auto;color:var(--text)}
.fnd-table tr.expand .ev p{margin:0;color:var(--text);font-size:13px}.fnd-table tr.expand .ev .links{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}.fnd-table tr.expand .ev .links a{display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:3px 8px;border:1px solid var(--border);border-radius:4px;background:var(--surface);color:var(--brand)}
.empty-row td{text-align:center;color:var(--text-faint);padding:32px;font-style:italic}
.fnd-foot{margin-top:10px;font-size:12px;color:var(--text-faint);display:flex;justify-content:space-between}
.ent-grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}@media(max-width:1024px){.ent-grid{grid-template-columns:1fr}}
.ent-bars{display:flex;flex-direction:column;gap:8px}.ent-bar{display:grid;grid-template-columns:140px 1fr 50px;gap:10px;align-items:center;font-size:13px}.ent-bar .lab{color:var(--text-muted)}.ent-bar .track{height:18px;background:var(--surface-2);border-radius:4px;overflow:hidden;border:1px solid var(--border)}.ent-bar .fill{height:100%;background:var(--brand);border-radius:3px}.ent-bar .n{text-align:right;font-weight:600;color:var(--text)}
.graph-wrap svg{width:100%;height:280px;display:block;background:var(--surface-2);border-radius:var(--radius-sm);border:1px solid var(--border)}
.graph-legend{display:flex;gap:14px;flex-wrap:wrap;margin-top:10px;font-size:12px;color:var(--text-muted)}.graph-legend span{display:inline-flex;align-items:center;gap:5px}.graph-legend i{width:10px;height:10px;border-radius:50%;display:inline-block}
footer.app{padding:24px 32px 40px;border-top:1px solid var(--border);background:var(--surface);margin-top:24px}.foot-row{max-width:1440px;margin:0 auto;display:grid;grid-template-columns:1fr auto;gap:24px;align-items:start}.versions{font-size:12px;color:var(--text-faint)}.versions table{border-collapse:collapse;margin-top:6px}.versions td{padding:2px 12px 2px 0;font-family:var(--mono);font-size:11.5px}
.foot-actions{display:flex;gap:8px}.btn{display:inline-flex;align-items:center;gap:6px;padding:7px 12px;border:1px solid var(--border);border-radius:6px;background:var(--surface-2);color:var(--text-muted);font-size:12.5px;font-weight:500}
.fw{display:inline-flex;align-items:center;padding:1px 6px;margin-right:4px;border-radius:4px;font-size:10.5px;font-weight:600;line-height:1.5;letter-spacing:.02em;color:#fff;font-family:var(--mono);white-space:nowrap}
.fw-cis{background:#d97706}.fw-nist{background:#374151}.fw-mitre{background:#b91c1c}.fw-eidsca{background:#1f6feb}.fw-eidas{background:#7c3aed}.fw-soc{background:#0e7490}.fw-iso{background:#0f766e}.fw-mcsb{background:#005a9e}.fw-caf{background:#1e3a8a}.fw-waf{background:#3a7d0a}.fw-cisa{background:#0f766e}.fw-orca{background:#0891b2}.fw-default{background:#475569}
.tool-chip{display:inline-flex;align-items:center;gap:4px;padding:1px 6px;border-radius:4px;font-family:var(--mono);font-size:10.5px;font-weight:600;color:var(--text-muted);background:var(--surface-2);border:1px solid var(--border)}
.rule-id{font-family:var(--mono);font-size:11px;color:var(--text-faint);background:var(--surface-2);padding:1px 5px;border-radius:3px;border:1px solid var(--border);margin-right:6px}
</style>
</head>
<body>
<header class='app' role='banner'>
  <div class='hdr-row'>
    <div class='brand'><span>Azure Analyzer</span><span class='pill ghost'>report v3</span></div>
    <div class='tenant'><strong>tenant</strong> · $(@($subs).Count) subs</div>
    <div class='kpi'><strong>$(HE $date)</strong></div>
    <div class='score'><div class='score-text'><span class='num'>$posture<span style='font-size:11px;color:var(--text-faint);font-weight:500'> ($compliantPct/100)</span></span><span class='lbl'>Posture</span></div></div>
    <div class='sev-strip' role='group' aria-label='Findings by severity'>
      <div class='sev-cnt sev-crit'><span class='n'>$($sevCount['crit'])</span><span class='l'>Crit</span></div>
      <div class='sev-cnt sev-high'><span class='n'>$($sevCount['high'])</span><span class='l'>High</span></div>
      <div class='sev-cnt sev-med'><span class='n'>$($sevCount['med'])</span><span class='l'>Med</span></div>
      <div class='sev-cnt sev-low'><span class='n'>$($sevCount['low'])</span><span class='l'>Low</span></div>
      <div class='sev-cnt sev-info'><span class='n'>$($sevCount['info'])</span><span class='l'>Info</span></div>
    </div>
    <div class='kpis' aria-label='Scan KPIs'><span class='kpi'><strong>$(@($manifestTools).Count)</strong> tools</span><span class='kpi'><strong>$entityCount</strong> entities</span><span class='kpi'><strong>$compliantPct%</strong> compliant</span></div>
    <button class='theme-btn' id='themeBtn' title='Toggle theme' aria-label='Toggle dark mode'>🌓</button>
  </div>
</header>
<nav class='sub' aria-label='Section'><div class='sub-row'><a href='#overview' class='active'>Overview</a><a href='#coverage'>Tool coverage</a><a href='#heatmap'>Heatmap</a><a href='#risks'>Top risks</a><a href='#findings'>Findings</a><a href='#entities'>Entities</a></div></nav>
<main>
<section class='section' id='overview'>
  <h2>Overview <span class='badge'>executive summary</span></h2>
  <div class='over-grid'>
    <div class='card card-pad exec'>
      <p><strong>Run summary</strong>: scanned <strong>$total findings</strong> across <strong>$(@($manifestTools).Count) tools</strong> and <strong>$entityCount entities</strong>. Overall compliance is <strong>$compliantPct%</strong>.</p>
      <p>Critical and High findings are prioritized in top risks. Schema 2.2 fields render when present and are skipped when absent.</p>
      <div class='pillars' aria-label='Pillar breakdown'>
        <h3 style='margin-bottom:4px'>Pillar breakdown (non-pass)</h3>
        $pillarSummaryHtml
      </div>
      $trendHtml
    </div>
    <div class='card card-pad'><h3 style='margin-bottom:10px'>Top recommendations</h3><div class='recs' id='topRecs'>$topRecsHtml</div></div>
  </div>
</section>
<section class='section' id='coverage'><h2>Tool coverage <span class='badge'>$(@($manifestTools).Count) registered</span></h2><div id='covRoot'>$($coverageHtml -join "`n")</div></section>
<section class='section' id='heatmap'>
  <h2>Heatmap <span class='badge'>control density</span></h2>
  <div class='card hm-wrap'>
    <div class='hm-toggle' role='tablist' aria-label='Heatmap view'>
      <button class='on' data-hm='domain'>Control domain × Subscription</button>
      <button data-hm='toolsev'>Tool × Severity</button>
      <button data-hm='fwsub'>Framework × Subscription</button>
    </div>
    <div id='hmRoot'></div>
    <div class='hm-legend'><span>Fewer findings</span><span class='grad' aria-hidden='true'></span><span>More findings</span></div>
  </div>
</section>
<section class='section' id='risks'><h2>Top risks <span class='badge'>ranked by impact</span></h2><div class='risks' id='risksRoot'>$riskRowsHtml</div></section>
<section class='section' id='findings'>
  <h2>Findings <span class='badge' id='fndCountBadge'>$total of $total</span></h2>
  <div class='fnd-toolbar'>
    <input type='search' id='fndSearch' placeholder='Search rule, entity, message' aria-label='Search findings'>
    <div class='sev-filter' role='group' aria-label='Severity filter'>
      <button data-sev='all' class='on'>All</button><button data-sev='crit'>Crit</button><button data-sev='high'>High</button><button data-sev='med'>Med</button><button data-sev='low'>Low</button><button data-sev='info'>Info</button>
    </div>
    <select id='fndTool' aria-label='Tool'><option value=''>All tools</option></select>
    <select id='fndSub' aria-label='Subscription'><option value=''>All subscriptions</option></select>
    <select id='fndStatus' aria-label='Status'><option value=''>All statuses</option><option value='Fail'>Fail</option><option value='Pass'>Pass</option><option value='Warning'>Warning</option></select>
    <button class='btn' id='exportCsv'>Export CSV</button>
  </div>
  <table class='fnd-table' id='fndTable'>
    <thead><tr><th data-sort='severity' class='sorted'>Sev <span class='arr'>▾</span></th><th data-sort='rule'>Rule <span class='arr'>▾</span></th><th data-sort='entity'>Entity <span class='arr'>▾</span></th><th data-sort='sub'>Subscription <span class='arr'>▾</span></th><th data-sort='tool'>Tool <span class='arr'>▾</span></th><th data-sort='status'>Status <span class='arr'>▾</span></th></tr></thead>
    <tbody id='fndBody'>
$($findingRows -join "`n")
    </tbody>
  </table>
  <div class='fnd-foot'><span id='fndShown'>$total shown</span><span>Click any row to expand evidence and remediation</span></div>
</section>
<section class='section' id='entities'>
  <h2>Entities <span class='badge'>$entityCount total</span></h2>
  <div class='ent-grid'>
    <div class='card card-pad'><h3 style='margin-bottom:14px'>Inventory by type</h3><div class='ent-bars' id='entBars'>$entityBarsHtml</div></div>
    <div class='card card-pad'><h3 style='margin-bottom:10px'>Blast radius: identity teaser</h3><p class='muted' style='margin:0 0 10px;font-size:12.5px'>Edges preview from entity graph.</p><div class='graph-wrap'><svg viewBox='0 0 600 280'><g stroke='var(--border-strong)' stroke-width='1' opacity='.7'><line x1='80' y1='140' x2='220' y2='100'/><line x1='220' y1='100' x2='380' y2='80'/><line x1='380' y1='80' x2='520' y2='70'/></g><g><circle cx='80' cy='140' r='14' fill='var(--high)'/><circle cx='220' cy='100' r='10' fill='var(--brand)'/><circle cx='380' cy='80' r='8' fill='var(--accent)'/><rect x='510' y='62' width='22' height='16' rx='3' fill='var(--med)'/></g></svg><div class='graph-legend'><span><i style='background:var(--high)'></i>Identity</span><span><i style='background:var(--brand)'></i>Group</span><span><i style='background:var(--accent)'></i>Service principal</span><span><i style='background:var(--med)'></i>Resource</span></div></div></div>
  </div>
</section>
</main>
<footer class='app'>
  <div class='foot-row'>
    <div class='versions'><strong style='color:var(--text)'>Tool versions used in this run</strong><table>$($toolVersionRows -join "`n")</table><div style='margin-top:10px'>Generated by <a href='https://github.com/martinopedal/azure-analyzer'>azure-analyzer</a> · Schema 2.2 · Report v3 · <a href='../README.md'>Docs</a></div></div>
    <div class='foot-actions'><button class='btn' onclick='window.print()'>Print</button><a class='btn' href='#overview'>Top</a></div>
  </div>
</footer>
<script type='application/json' id='hmModel'>$hmJson</script>
<script>
(function(){
'use strict';
const themeBtn=document.getElementById('themeBtn');
const root=document.documentElement;
const saved=localStorage.getItem('aa-theme');
if(saved==='dark'){setTheme('dark');}
function setTheme(t){root.setAttribute('data-theme',t);localStorage.setItem('aa-theme',t);}
themeBtn.addEventListener('click',()=>setTheme(root.getAttribute('data-theme')==='dark'?'light':'dark'));

const state={search:'',sev:'all',tool:'',sub:'',status:'',sortKey:'severity',sortDir:1,rule:''};
const SEV_ORDER={crit:0,high:1,med:2,low:3,info:4};

function collectRows(){
  const body=document.getElementById('fndBody');
  const rows=[];
  body.querySelectorAll('tr.row').forEach(r=>{
    const id=r.dataset.id;
    const ex=body.querySelector("tr.expand[data-parent-id='" + id + "']");
    rows.push({row:r,expand:ex});
  });
  return rows;
}

function ensureSelectOptions(){
  const tools=[...new Set(collectRows().map(x=>x.row.dataset.tool).filter(Boolean))].sort();
  const subs=[...new Set(collectRows().map(x=>x.row.dataset.sub).filter(Boolean))].sort();
  const toolSel=document.getElementById('fndTool');
  const subSel=document.getElementById('fndSub');
  tools.forEach(t=>{const o=document.createElement('option');o.value=t;o.textContent=t;toolSel.appendChild(o)});
  subs.forEach(s=>{const o=document.createElement('option');o.value=s;o.textContent=s;subSel.appendChild(o)});
}

function applyFilters(){
  let shown=0;
  collectRows().forEach(pair=>{
    const r=pair.row;
    const txt=r.textContent.toLowerCase();
    const okSev=(state.sev==='all'||r.dataset.severity===state.sev);
    const okTool=(!state.tool||r.dataset.tool===state.tool);
    const okSub=(!state.sub||r.dataset.sub===state.sub);
    const okStatus=(!state.status||r.dataset.status===state.status);
    const okRule=(!state.rule||r.dataset.rule===state.rule);
    const okSearch=(!state.search||txt.includes(state.search));
    const show=okSev&&okTool&&okSub&&okStatus&&okRule&&okSearch;
    r.style.display=show?'':'none';
    if(!show && pair.expand){pair.expand.hidden=true;pair.expand.style.display='none';}
    if(show){shown++;}
  });
  const total=collectRows().length;
  document.getElementById('fndCountBadge').textContent=shown + ' of ' + total;
  document.getElementById('fndShown').textContent=shown + ' shown';
}

function sortRows(){
  const body=document.getElementById('fndBody');
  const pairs=collectRows();
  pairs.sort((a,b)=>{
    let av='',bv='';
    if(state.sortKey==='severity'){av=SEV_ORDER[a.row.dataset.severity]??99;bv=SEV_ORDER[b.row.dataset.severity]??99;}
    else if(state.sortKey==='rule'){av=a.row.dataset.rule||'';bv=b.row.dataset.rule||'';}
    else if(state.sortKey==='entity'){av=a.row.dataset.entity||'';bv=b.row.dataset.entity||'';}
    else if(state.sortKey==='sub'){av=a.row.dataset.sub||'';bv=b.row.dataset.sub||'';}
    else if(state.sortKey==='tool'){av=a.row.dataset.tool||'';bv=b.row.dataset.tool||'';}
    else {av=a.row.dataset.status||'';bv=b.row.dataset.status||'';}
    if(av<bv)return -1*state.sortDir;
    if(av>bv)return 1*state.sortDir;
    return 0;
  });
  pairs.forEach(p=>{body.appendChild(p.row);if(p.expand)body.appendChild(p.expand);});
}

function bindEvents(){
  document.getElementById('fndSearch').addEventListener('input',e=>{state.search=(e.target.value||'').toLowerCase();applyFilters();});
  document.querySelectorAll('.sev-filter button').forEach(b=>{
    b.addEventListener('click',()=>{document.querySelectorAll('.sev-filter button').forEach(x=>x.classList.remove('on'));b.classList.add('on');state.sev=b.dataset.sev;applyFilters();});
  });
  document.getElementById('fndTool').addEventListener('change',e=>{state.tool=e.target.value;applyFilters();});
  document.getElementById('fndSub').addEventListener('change',e=>{state.sub=e.target.value;applyFilters();});
  document.getElementById('fndStatus').addEventListener('change',e=>{state.status=e.target.value;applyFilters();});
  document.querySelectorAll('.fnd-table th[data-sort]').forEach(th=>{
    th.addEventListener('click',()=>{const k=th.dataset.sort;if(state.sortKey===k){state.sortDir*=-1;}else{state.sortKey=k;state.sortDir=1;}document.querySelectorAll('.fnd-table th').forEach(x=>x.classList.remove('sorted'));th.classList.add('sorted');sortRows();applyFilters();});
  });
  collectRows().forEach(pair=>{
    pair.row.addEventListener('click',()=>{if(!pair.expand)return;const open=!pair.expand.hidden;pair.expand.hidden=open;pair.expand.style.display=open?'none':'';});
  });
  document.getElementById('exportCsv').addEventListener('click',()=>{
    const header=['severity','rule','entity','subscription','tool','status'];
    const data=[header.join(',')];
    collectRows().forEach(pair=>{
      if(pair.row.style.display==='none')return;
      const vals=[pair.row.dataset.severity,pair.row.dataset.rule,pair.row.dataset.entity,pair.row.dataset.sub,pair.row.dataset.tool,pair.row.dataset.status]
        .map(v=>'"' + String(v||'').replace(/"/g,'""') + '"');
      data.push(vals.join(','));
    });
    const blob=new Blob([data.join('\n')],{type:'text/csv'});
    const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='findings.csv';a.click();
  });
}

window.focusRisk=function(ruleKey){
  state.rule=ruleKey||'';
  const search=document.getElementById('fndSearch');
  if(search){search.value='';state.search='';}
  applyFilters();
};

const hmModel=JSON.parse(document.getElementById('hmModel').textContent||'{}');
let hmMode=hmModel.defaultMode||'domain';
function renderHeatmap(){
  const root=document.getElementById('hmRoot');
  const matrix=(hmModel.matrices||{})[hmMode];
  if(!matrix||!matrix.rows||!matrix.cols||matrix.rows.length===0||matrix.cols.length===0){root.innerHTML='<p class="muted">No data for this heatmap view.</p>';return;}
  let max=1;matrix.rows.forEach(r=>matrix.cols.forEach(c=>{const n=(matrix.cells||{})[r + '||' + c]||0;if(n>max)max=n;}));
  let html='<table class="hm-table"><thead><tr><th>'+matrix.rowLabel+'</th>'+matrix.cols.map(c=>'<th>'+labelCol(c)+'</th>').join('')+'</tr></thead><tbody>';
  matrix.rows.forEach(r=>{html+='<tr><td class="row-h">'+labelRow(r)+'</td>';matrix.cols.forEach(c=>{const n=(matrix.cells||{})[r + '||' + c]||0;if(n===0){html+='<td class="hm-cell empty">·</td>';return;}const intensity=(.25+.75*(n/max)).toFixed(2);const sev=colorSeverity(r,c);html+='<td class="hm-cell" style="background:var(--'+sev+');opacity:'+intensity+'">'+n+'</td>';});html+='</tr>';});
  html+='</tbody></table>';root.innerHTML=html;
}
function labelRow(v){if(hmMode==='toolsev'){return (hmModel.toolLabels&&hmModel.toolLabels[v])||v;}return v;}
function labelCol(v){if(hmMode==='toolsev'){return (hmModel.severityLabels&&hmModel.severityLabels[v])||v;}return v;}
function colorSeverity(r,c){if(hmMode==='toolsev'){return c;}const x=String(r||'').toLowerCase();if(x.includes('crit'))return 'crit';if(x.includes('high'))return 'high';if(x.includes('med'))return 'med';if(x.includes('low'))return 'low';return 'info';}

document.querySelectorAll('.hm-toggle button').forEach(b=>{b.addEventListener('click',()=>{document.querySelectorAll('.hm-toggle button').forEach(x=>x.classList.remove('on'));b.classList.add('on');hmMode=b.dataset.hm;renderHeatmap();});});

const subLinks=document.querySelectorAll('.sub-row a');
const sections=Array.from(subLinks).map(a=>document.querySelector(a.getAttribute('href')));
window.addEventListener('scroll',()=>{const y=window.scrollY+140;let active=0;sections.forEach((s,i)=>{if(s&&s.offsetTop<=y)active=i});subLinks.forEach((a,i)=>a.classList.toggle('active',i===active));},{passive:true});

ensureSelectOptions();
bindEvents();
sortRows();
applyFilters();
renderHeatmap();
})();
</script>
</body>
</html>
"@

$sanitizedHtml = Remove-Credentials $html
Set-Content -Path $OutputPath -Value $sanitizedHtml -Encoding UTF8
Write-Host "HTML report written to: $OutputPath"
