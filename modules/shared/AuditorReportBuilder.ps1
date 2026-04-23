#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AuditorReportBuilderVersion = '1.0.0'

$sanitizePath = Join-Path $PSScriptRoot 'Sanitize.ps1'
if (Test-Path -LiteralPath $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

function _ARB-HasProp {
    param([object]$Obj,[string]$Name)
    return ($null -ne $Obj -and $Obj.PSObject.Properties[$Name])
}

function _ARB-GetProp {
    param([object]$Obj,[string]$Name,[object]$Default = $null)
    if (_ARB-HasProp -Obj $Obj -Name $Name) { return $Obj.$Name }
    return $Default
}

function _ARB-ReadJson {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100)
}

function _ARB-SeverityWeight {
    param([string]$Severity)
    switch -Regex (($Severity ?? '').Trim().ToLowerInvariant()) {
        '^critical$' { return 5 }
        '^high$' { return 4 }
        '^medium$|^moderate$' { return 3 }
        '^low$' { return 2 }
        default { return 1 }
    }
}

function _ARB-SeverityLabel {
    param([string]$Severity)
    switch (_ARB-SeverityWeight $Severity) {
        5 { 'Critical' }
        4 { 'High' }
        3 { 'Medium' }
        2 { 'Low' }
        default { 'Info' }
    }
}

function _ARB-CanonicalFramework {
    param([string]$Framework)
    $f = (($Framework ?? '').Trim()).ToUpperInvariant()
    if ($f.StartsWith('CIS')) { return 'CIS' }
    if ($f.StartsWith('NIST')) { return 'NIST' }
    if ($f -eq 'MCSB' -or $f.StartsWith('MICROSOFT CLOUD SECURITY BENCHMARK')) { return 'MCSB' }
    if ($f.StartsWith('ISO')) { return 'ISO27001' }
    return $f
}

function _ARB-ExtractMappings {
    param([object]$Finding)

    $raw = @(_ARB-GetProp -Obj $Finding -Name 'ComplianceMappings' -Default @())
    if ($raw.Count -eq 0 -and (_ARB-HasProp -Obj $Finding -Name 'Frameworks')) {
        $raw = @($Finding.Frameworks)
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($m in $raw) {
        if ($null -eq $m) { continue }
        if ($m -is [string]) {
            $txt = [string]$m
            $framework = _ARB-CanonicalFramework -Framework $txt
            $items.Add([pscustomobject]@{
                Framework = $framework
                FrameworkVersion = ''
                ControlId = $txt
                ControlTitle = $txt
                Status = ''
                TotalControls = $null
            })
            continue
        }

        $framework = [string](_ARB-GetProp -Obj $m -Name 'Framework' -Default (_ARB-GetProp -Obj $m -Name 'framework' -Default (_ARB-GetProp -Obj $m -Name 'Name' -Default '')))
        $framework = _ARB-CanonicalFramework -Framework $framework
        $controlId = [string](_ARB-GetProp -Obj $m -Name 'ControlId' -Default (_ARB-GetProp -Obj $m -Name 'controlId' -Default (_ARB-GetProp -Obj $m -Name 'Id' -Default (_ARB-GetProp -Obj $m -Name 'id' -Default ''))))
        if ([string]::IsNullOrWhiteSpace($controlId)) {
            $controlId = [string](_ARB-GetProp -Obj $m -Name 'Control' -Default (_ARB-GetProp -Obj $m -Name 'control' -Default 'unmapped-control'))
        }
        $controlTitle = [string](_ARB-GetProp -Obj $m -Name 'ControlTitle' -Default (_ARB-GetProp -Obj $m -Name 'Title' -Default ($controlId)))
        $totalControls = _ARB-GetProp -Obj $m -Name 'TotalControls' -Default (_ARB-GetProp -Obj $m -Name 'totalControls' -Default (_ARB-GetProp -Obj $m -Name 'FrameworkTotal' -Default $null))
        $items.Add([pscustomobject]@{
            Framework = $framework
            FrameworkVersion = [string](_ARB-GetProp -Obj $m -Name 'FrameworkVersion' -Default (_ARB-GetProp -Obj $m -Name 'version' -Default ''))
            ControlId = $controlId
            ControlTitle = $controlTitle
            Status = [string](_ARB-GetProp -Obj $m -Name 'Status' -Default (_ARB-GetProp -Obj $m -Name 'status' -Default ''))
            TotalControls = $totalControls
        })
    }

    return $items.ToArray()
}

function _ARB-TierFromManifest {
    param([object]$Manifest,[string]$Tier)

    $manifestTier = [string](_ARB-GetProp -Obj $Manifest -Name 'SelectedTier' -Default '')
    if ([string]::IsNullOrWhiteSpace($manifestTier) -and (_ARB-HasProp -Obj $Manifest -Name 'report')) {
        $manifestTier = [string](_ARB-GetProp -Obj $Manifest.report -Name 'tier' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($manifestTier) -and (_ARB-HasProp -Obj $Manifest -Name 'Tier')) {
        $manifestTier = [string]$Manifest.Tier
    }

    $resolved = if (-not [string]::IsNullOrWhiteSpace($manifestTier)) { $manifestTier } elseif (-not [string]::IsNullOrWhiteSpace($Tier)) { $Tier } else { 'PureJson' }
    if ($resolved -notin @('PureJson','EmbeddedSqlite','SidecarSqlite','PodeViewer')) { return 'PureJson' }
    return $resolved
}

function _ARB-SectionCatalog {
    param([string]$Tier,[string[]]$Frameworks)

    $modeByTier = @{
        PureJson = @{ exec='prose'; control='table+heatmap'; attack='full-cytoscape'; resilience='table'; policy='table'; remediation='grouped-list'; evidence='inline-download' }
        EmbeddedSqlite = @{ exec='prose'; control='table+heatmap'; attack='paginated-cytoscape'; resilience='table'; policy='table'; remediation='grouped-list'; evidence='inline-download' }
        SidecarSqlite = @{ exec='prose'; control='headline+deep-link'; attack='paginated-subgraph'; resilience='headline+deep-link'; policy='headline+deep-link'; remediation='top-20+deep-link'; evidence='sidecar-files' }
        PodeViewer = @{ exec='kpi+prose'; control='tile+deep-link'; attack='server-queried-neighborhood'; resilience='tile+deep-link'; policy='aggregated-counts'; remediation='top-10-tile'; evidence='server-streamed' }
    }

    $baseline = $modeByTier.PureJson
    $selected = $modeByTier[$Tier]

    $sections = New-Object System.Collections.Generic.List[object]
    $sections.Add([pscustomobject]@{ id = 'exec'; title = 'Executive Summary'; renderingMode = $selected.exec })
    foreach ($fw in $Frameworks) {
        $idSuffix = switch (_ARB-CanonicalFramework $fw) {
            'CIS' { 'cis' }
            'NIST' { 'nist' }
            'MCSB' { 'mcsb' }
            default { 'iso' }
        }
        $sections.Add([pscustomobject]@{
            id = "control.$idSuffix"
            title = "$fw Coverage"
            renderingMode = $selected.control
        })
    }
    $sections.Add([pscustomobject]@{ id = 'attackpath'; title = 'Attack Paths'; renderingMode = $selected.attack })
    $sections.Add([pscustomobject]@{ id = 'resilience'; title = 'Blast-Radius / Resilience'; renderingMode = $selected.resilience })
    $sections.Add([pscustomobject]@{ id = 'policy'; title = 'Policy Coverage vs. ALZ'; renderingMode = $selected.policy })
    $sections.Add([pscustomobject]@{ id = 'remediation'; title = 'Ready to Remediate'; renderingMode = $selected.remediation })
    $sections.Add([pscustomobject]@{ id = 'evidence'; title = 'Evidence Export'; renderingMode = $selected.evidence })

    $degradations = New-Object System.Collections.Generic.List[object]
    foreach ($section in $sections) {
        $tier1Mode = switch -Wildcard ($section.id) {
            'exec' { $baseline.exec }
            'control.*' { $baseline.control }
            'attackpath' { $baseline.attack }
            'resilience' { $baseline.resilience }
            'policy' { $baseline.policy }
            'remediation' { $baseline.remediation }
            'evidence' { $baseline.evidence }
            default { $section.renderingMode }
        }
        if ([string]$section.renderingMode -ne [string]$tier1Mode) {
            $degradations.Add([pscustomobject]@{
                sectionId = [string]$section.id
                feature = [string]$section.id
                tier1Mode = [string]$tier1Mode
                thisTierMode = [string]$section.renderingMode
                reason = "Tier $Tier rendering optimization"
            })
        }
    }

    return [pscustomobject]@{ Sections = $sections.ToArray(); Degradations = $degradations.ToArray() }
}

function Resolve-AuditorContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $EntitiesPath,
        [Parameter(Mandatory)] [string] $ManifestPath,
        [string] $TriagePath = '',
        [string] $PreviousRunPath = '',
        [string] $Tier
    )

    if (-not (Test-Path -LiteralPath $InputPath)) { throw "InputPath not found: $InputPath" }
    if (-not (Test-Path -LiteralPath $EntitiesPath)) { throw "EntitiesPath not found: $EntitiesPath" }
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "ManifestPath not found: $ManifestPath" }

    $findingsDoc = _ARB-ReadJson -Path $InputPath
    $findings = @($findingsDoc)
    if ($findings.Count -eq 1 -and (_ARB-HasProp -Obj $findings[0] -Name 'Findings')) {
        $findings = @($findings[0].Findings)
    }

    $entitiesDoc = _ARB-ReadJson -Path $EntitiesPath
    $entities = @()
    $edges = @()
    if (_ARB-HasProp -Obj $entitiesDoc -Name 'Entities') {
        $entities = @($entitiesDoc.Entities)
        $edges = @(_ARB-GetProp -Obj $entitiesDoc -Name 'Edges' -Default @())
    } else {
        $entities = @($entitiesDoc)
    }

    $manifestDoc = _ARB-ReadJson -Path $ManifestPath
    $tierValue = _ARB-TierFromManifest -Manifest $manifestDoc -Tier $Tier

    $triageDoc = $null
    if (-not [string]::IsNullOrWhiteSpace($TriagePath) -and (Test-Path -LiteralPath $TriagePath)) {
        $triageDoc = _ARB-ReadJson -Path $TriagePath
    }

    $previousFindings = @()
    if (-not [string]::IsNullOrWhiteSpace($PreviousRunPath) -and (Test-Path -LiteralPath $PreviousRunPath)) {
        $prevDoc = _ARB-ReadJson -Path $PreviousRunPath
        $previousFindings = @($prevDoc)
        if ($previousFindings.Count -eq 1 -and (_ARB-HasProp -Obj $previousFindings[0] -Name 'Findings')) {
            $previousFindings = @($previousFindings[0].Findings)
        }
    }

    $subscriptions = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $findings) {
        $sub = [string](_ARB-GetProp -Obj $f -Name 'SubscriptionId' -Default '')
        if ([string]::IsNullOrWhiteSpace($sub)) {
            $resourceId = [string](_ARB-GetProp -Obj $f -Name 'ResourceId' -Default '')
            if ($resourceId -match '(?i)/subscriptions/([^/]+)') { $sub = $Matches[1] }
        }
        if (-not [string]::IsNullOrWhiteSpace($sub)) { $null = $subscriptions.Add($sub) }
    }

    return @{
        Tier = $tierValue
        Manifest = $manifestDoc
        ManifestPath = $ManifestPath
        Findings = @($findings)
        Entities = @($entities)
        Edges = @($edges)
        Triage = $triageDoc
        PreviousFindings = @($previousFindings)
        RunId = "run-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))"
        Scopes = [pscustomobject]@{
            SubscriptionCount = $subscriptions.Count
            Subscriptions = @($subscriptions)
            EntityCount = @($entities).Count
        }
    }
}

function Get-AuditorExecutiveSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [object[]] $PreviousFindings = @(),
        [string[]] $ControlFrameworks = @('CIS','NIST','MCSB','ISO27001')
    )

    $nonCompliant = @($Findings | Where-Object { $_.Compliant -ne $true })

    $severityCounts = [ordered]@{}
    foreach ($sev in @('Critical','High','Medium','Low','Info')) {
        $severityCounts[$sev] = @($nonCompliant | Where-Object { (_ARB-SeverityLabel $_.Severity) -eq $sev }).Count
    }

    $coverage = [ordered]@{}
    foreach ($fw in $ControlFrameworks) {
        $canonical = _ARB-CanonicalFramework $fw
        $controlsSeen = New-Object System.Collections.Generic.HashSet[string]
        $controlsCovered = New-Object System.Collections.Generic.HashSet[string]
        $declaredTotals = New-Object System.Collections.Generic.List[int]

        foreach ($f in $Findings) {
            $mappings = @(_ARB-ExtractMappings -Finding $f | Where-Object { (_ARB-CanonicalFramework $_.Framework) -eq $canonical })
            foreach ($m in $mappings) {
                $key = [string]$m.ControlId
                if (-not [string]::IsNullOrWhiteSpace($key)) {
                    $null = $controlsSeen.Add($key)
                    if ($f.Compliant -ne $true) { $null = $controlsCovered.Add($key) }
                }
                if ($m.TotalControls -as [int]) { $declaredTotals.Add([int]$m.TotalControls) }
            }
        }

        $covered = $controlsCovered.Count
        $total = if ($declaredTotals.Count -gt 0) { ($declaredTotals | Measure-Object -Maximum).Maximum } else { [math]::Max($controlsSeen.Count, $covered) }
        if ($total -lt 1) { $total = 0 }
        $pct = if ($total -gt 0) { [math]::Round(($covered / $total) * 100, 1) } else { 0 }

        $coverage[$canonical] = [pscustomobject]@{ covered = $covered; total = $total; pct = $pct }
    }

    $sortedRisks = @(
        $nonCompliant |
            Sort-Object @{ Expression = { _ARB-SeverityWeight $_.Severity }; Descending = $true }, @{ Expression = { [string](_ARB-GetProp $_ 'Title' '') }; Descending = $false } |
            Select-Object -First 10
    )

    $topRisks = @($sortedRisks | ForEach-Object {
        [pscustomobject]@{
            id = [string](_ARB-GetProp -Obj $_ -Name 'Id' -Default ([guid]::NewGuid().ToString()))
            title = [string](_ARB-GetProp -Obj $_ -Name 'Title' -Default 'Untitled finding')
            severity = _ARB-SeverityLabel ([string](_ARB-GetProp -Obj $_ -Name 'Severity' -Default 'Info'))
            entity = [string](_ARB-GetProp -Obj $_ -Name 'EntityId' -Default (_ARB-GetProp -Obj $_ -Name 'ResourceId' -Default ''))
            framework = [string]((_ARB-ExtractMappings -Finding $_ | Select-Object -First 1).ControlId)
            remediation = [string](_ARB-GetProp -Obj $_ -Name 'Remediation' -Default '')
            citation = New-AuditorCitation -Finding $_ -Style 'workpaper'
        }
    })

    $currentIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Findings | ForEach-Object { [string](_ARB-GetProp $_ 'Id' '') }))
    $previousIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($PreviousFindings | ForEach-Object { [string](_ARB-GetProp $_ 'Id' '') }))
    $added = @($currentIds | Where-Object { $_ -and -not $previousIds.Contains($_) }).Count
    $resolved = @($previousIds | Where-Object { $_ -and -not $currentIds.Contains($_) }).Count

    $previousById = @{}
    foreach ($p in $PreviousFindings) {
        $id = [string](_ARB-GetProp -Obj $p -Name 'Id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($id)) { $previousById[$id] = _ARB-SeverityLabel ([string](_ARB-GetProp -Obj $p -Name 'Severity' -Default 'Info')) }
    }
    $changedSeverity = 0
    foreach ($f in $Findings) {
        $id = [string](_ARB-GetProp -Obj $f -Name 'Id' -Default '')
        if ([string]::IsNullOrWhiteSpace($id) -or -not $previousById.ContainsKey($id)) { continue }
        if ($previousById[$id] -ne (_ARB-SeverityLabel ([string](_ARB-GetProp -Obj $f -Name 'Severity' -Default 'Info')))) { $changedSeverity++ }
    }

    $sources = @($Findings | ForEach-Object { [string](_ARB-GetProp -Obj $_ -Name 'Source' -Default '') } | Where-Object { $_ } | Select-Object -Unique)

    return [pscustomobject]@{
        scopeStatement = "Findings: $($Findings.Count); non-compliant: $($nonCompliant.Count)."
        methodology = "Azure Resource Graph snapshot + $($sources.Count) scanners ($($sources -join ', '))."
        severityCounts = [pscustomobject]$severityCounts
        controlCoveragePct = [pscustomobject]$coverage
        topRisks = @($topRisks)
        diff = [pscustomobject]@{
            previousRunId = if ($PreviousFindings.Count -gt 0) { 'previous-run' } else { '' }
            added = $added
            resolved = $resolved
            changedSeverity = $changedSeverity
        }
    }
}

function Get-AuditorControlDomainSections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [Parameter(Mandatory)] [string[]] $Frameworks
    )

    $sections = New-Object System.Collections.Generic.List[object]

    foreach ($fw in $Frameworks) {
        $canonical = _ARB-CanonicalFramework $fw
        $controls = @{}

        foreach ($f in $Findings) {
            $mappings = @(_ARB-ExtractMappings -Finding $f | Where-Object { (_ARB-CanonicalFramework $_.Framework) -eq $canonical })
            foreach ($m in $mappings) {
                $key = [string]$m.ControlId
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                if (-not $controls.ContainsKey($key)) {
                    $controls[$key] = [pscustomobject]@{
                        id = $key
                        title = if ([string]::IsNullOrWhiteSpace([string]$m.ControlTitle)) { $key } else { [string]$m.ControlTitle }
                        status = 'pass'
                        findingCount = 0
                        severityRollupWeight = 1
                        remediation = ''
                        evidenceCitation = ''
                        topFindings = [System.Collections.Generic.List[string]]::new()
                    }
                }

                $entry = $controls[$key]
                if ($f.Compliant -ne $true) {
                    $entry.status = 'fail'
                    $entry.findingCount = [int]$entry.findingCount + 1
                    $sevWeight = _ARB-SeverityWeight ([string](_ARB-GetProp -Obj $f -Name 'Severity' -Default 'Info'))
                    if ($sevWeight -gt [int]$entry.severityRollupWeight) { $entry.severityRollupWeight = $sevWeight }
                    $fid = [string](_ARB-GetProp -Obj $f -Name 'Id' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($fid) -and -not $entry.topFindings.Contains($fid)) { $entry.topFindings.Add($fid) }
                    if ([string]::IsNullOrWhiteSpace([string]$entry.remediation)) { $entry.remediation = [string](_ARB-GetProp -Obj $f -Name 'Remediation' -Default '') }
                    if ([string]::IsNullOrWhiteSpace([string]$entry.evidenceCitation)) { $entry.evidenceCitation = New-AuditorCitation -Finding $f -Style 'workpaper' }
                }
            }
        }

        $ordered = @($controls.Values | Sort-Object @{ Expression = { [int]($_.status -eq 'fail') }; Descending = $true }, @{ Expression = { [int]$_.severityRollupWeight }; Descending = $true }, id)
        $renderedControls = @($ordered | ForEach-Object {
            [pscustomobject]@{
                id = $_.id
                title = $_.title
                status = $_.status
                findingCount = [int]$_.findingCount
                severityRollup = _ARB-SeverityLabel ([string]$_.severityRollupWeight)
                topFindings = @($_.topFindings | Select-Object -First 5)
                remediation = [string]$_.remediation
                evidenceCitation = [string]$_.evidenceCitation
            }
        })

        $passCount = @($renderedControls | Where-Object { $_.status -eq 'pass' }).Count
        $failCount = @($renderedControls | Where-Object { $_.status -eq 'fail' }).Count

        $sections.Add([pscustomobject]@{
            framework = $canonical
            frameworkVersion = ''
            controls = @($renderedControls)
            findingsByControl = [pscustomobject]($renderedControls | Group-Object -Property id -AsHashTable)
            coverageBar = [pscustomobject]@{ pass = $passCount; fail = $failCount; manual = 0; notApplicable = 0 }
        })
    }

    return $sections.ToArray()
}

function Get-AuditorAttackPathSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entities,
        [Parameter(Mandatory)] [string] $Tier
    )

    $entityArray = @($Entities)
    $edgeArray = @()
    if ($entityArray.Count -eq 1 -and (_ARB-HasProp -Obj $entityArray[0] -Name 'Edges')) {
        $edgeArray = @(_ARB-GetProp -Obj $entityArray[0] -Name 'Edges' -Default @())
    }

    $attackEdges = @($edgeArray | Where-Object {
        $r = [string](_ARB-GetProp -Obj $_ -Name 'Relation' -Default (_ARB-GetProp -Obj $_ -Name 'relation' -Default ''))
        $r -match '(?i)attack|privilege|admin|ownership|credential'
    })

    $mode = switch ($Tier) {
        'PodeViewer' { 'server-queried-neighborhood' }
        'SidecarSqlite' { 'paginated-subgraph' }
        'EmbeddedSqlite' { 'paginated-cytoscape' }
        default { 'full-cytoscape' }
    }

    return [pscustomobject]@{
        renderingMode = $mode
        pathCount = $attackEdges.Count
        paths = @($attackEdges | Select-Object -First 25)
        privilegedTargets = @($attackEdges | ForEach-Object { [string](_ARB-GetProp -Obj $_ -Name 'Target' -Default '') } | Where-Object { $_ } | Select-Object -Unique)
        message = if ($attackEdges.Count -gt 0) { 'Attack path indicators available.' } else { 'Attack path data unavailable; section degraded gracefully.' }
    }
}

function Get-AuditorResilienceSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entities,
        [Parameter(Mandatory)] [string] $Tier
    )

    $entityArray = @($Entities)
    $edgeArray = @()
    if ($entityArray.Count -eq 1 -and (_ARB-HasProp -Obj $entityArray[0] -Name 'Edges')) {
        $edgeArray = @(_ARB-GetProp -Obj $entityArray[0] -Name 'Edges' -Default @())
    }

    $resilienceRelations = @('DependsOn','RegionPinned','ZonePinned','BackedUpBy','FailsOverTo','ReplicatedTo')
    $resilienceEdges = @($edgeArray | Where-Object {
        $rel = [string](_ARB-GetProp -Obj $_ -Name 'Relation' -Default (_ARB-GetProp -Obj $_ -Name 'relation' -Default ''))
        $resilienceRelations -contains $rel
    })

    return [pscustomobject]@{
        renderingMode = if ($Tier -eq 'PodeViewer') { 'tile+deep-link' } elseif ($Tier -eq 'SidecarSqlite') { 'headline+deep-link' } else { 'table' }
        blastRadius = $resilienceEdges.Count
        top10Exposed = @($resilienceEdges | Group-Object -Property Source | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
            [pscustomobject]@{ entity = $_.Name; edgeCount = $_.Count }
        })
        message = if ($resilienceEdges.Count -gt 0) { 'Resilience graph edges detected.' } else { 'Resilience data unavailable; section degraded gracefully.' }
    }
}

function Get-AuditorPolicyCoverageSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entities,
        [Parameter(Mandatory)] [object[]] $Findings
    )

    $policyFindings = @($Findings | Where-Object {
        $src = [string](_ARB-GetProp -Obj $_ -Name 'Source' -Default '')
        $src -match '(?i)alz|policy|psrule'
    })

    $assigned = @($policyFindings | Where-Object { $_.Compliant -eq $true }).Count
    $gaps = @($policyFindings | Where-Object { $_.Compliant -ne $true }).Count

    return [pscustomobject]@{
        renderingMode = 'table'
        assignedVsReference = [pscustomobject]@{ assigned = $assigned; reference = $policyFindings.Count }
        alzGaps = @($policyFindings | Where-Object { $_.Compliant -ne $true } | Select-Object -First 50)
        recommendedRemediations = @($policyFindings | Where-Object { $_.Compliant -ne $true } | ForEach-Object { [string](_ARB-GetProp -Obj $_ -Name 'Remediation' -Default '') } | Where-Object { $_ } | Select-Object -Unique)
        gapCount = $gaps
    }
}

function Get-AuditorTriageAnnotations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [string] $TriagePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($TriagePath) -or -not (Test-Path -LiteralPath $TriagePath)) {
        return [pscustomobject]@{ enabled = $false; verdictByFinding = @{}; suggestedSuppressions = @() }
    }

    $triageDoc = _ARB-ReadJson -Path $TriagePath
    $items = @($triageDoc)
    if ($items.Count -eq 1 -and (_ARB-HasProp -Obj $items[0] -Name 'Findings')) {
        $items = @($items[0].Findings)
    }

    $verdictByFinding = @{}
    $suppressions = New-Object System.Collections.Generic.List[object]
    foreach ($i in $items) {
        $id = [string](_ARB-GetProp -Obj $i -Name 'Id' -Default (_ARB-GetProp -Obj $i -Name 'FindingId' -Default ''))
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $verdictByFinding[$id] = [string](_ARB-GetProp -Obj $i -Name 'Verdict' -Default (_ARB-GetProp -Obj $i -Name 'Priority' -Default ''))
        if ([string]$verdictByFinding[$id] -match '(?i)suppress|false positive|wontfix') {
            $suppressions.Add([pscustomobject]@{ id = $id; reason = [string](_ARB-GetProp -Obj $i -Name 'Rationale' -Default '') })
        }
    }

    return [pscustomobject]@{ enabled = $true; verdictByFinding = $verdictByFinding; suggestedSuppressions = $suppressions.ToArray() }
}

function Get-AuditorRemediationAppendix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings
    )

    $groups = @($Findings |
        Where-Object { $_.Compliant -ne $true } |
        Group-Object -Property { [string](_ARB-GetProp -Obj $_ -Name 'Remediation' -Default '') })

    $rows = @($groups | ForEach-Object {
        $rem = [string]$_.Name
        if ([string]::IsNullOrWhiteSpace($rem)) { $rem = 'No remediation text provided' }
        $weight = (@($_.Group | ForEach-Object { _ARB-SeverityWeight ([string](_ARB-GetProp -Obj $_ -Name 'Severity' -Default 'Info')) }) | Measure-Object -Sum).Sum
        $maxWeight = (@($_.Group | ForEach-Object { _ARB-SeverityWeight ([string](_ARB-GetProp -Obj $_ -Name 'Severity' -Default 'Info')) }) | Measure-Object -Maximum).Maximum
        [pscustomobject]@{
            remediation = $rem
            findingCount = @($_.Group).Count
            aggregateWeight = [int]$weight
            severityRollup = _ARB-SeverityLabel ([string]$maxWeight)
            snippets = @($_.Group | ForEach-Object { @(_ARB-GetProp -Obj $_ -Name 'RemediationSnippets' -Default @()) } | Where-Object { $_ })
            findings = @($_.Group)
        }
    } | Sort-Object @{ Expression = 'aggregateWeight'; Descending = $true }, @{ Expression = 'remediation'; Descending = $false })

    return [pscustomobject]@{ groupsByRemediation = @($rows) }
}

function Get-AuditorEvidenceExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [Parameter(Mandatory)] [string]   $OutputDirectory,
        [string[]] $Formats = @('csv','json')
    )

    $evidenceDir = Join-Path $OutputDirectory 'audit-evidence'
    if (-not (Test-Path -LiteralPath $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }

    $written = New-Object System.Collections.Generic.List[string]

    $safeRows = @($Findings | ForEach-Object {
        [pscustomobject]@{
            Id = [string](_ARB-GetProp -Obj $_ -Name 'Id' -Default '')
            Source = [string](_ARB-GetProp -Obj $_ -Name 'Source' -Default '')
            Severity = [string](_ARB-GetProp -Obj $_ -Name 'Severity' -Default '')
            Compliant = [bool](_ARB-GetProp -Obj $_ -Name 'Compliant' -Default $false)
            Title = Remove-Credentials ([string](_ARB-GetProp -Obj $_ -Name 'Title' -Default ''))
            EntityId = Remove-Credentials ([string](_ARB-GetProp -Obj $_ -Name 'EntityId' -Default (_ARB-GetProp -Obj $_ -Name 'ResourceId' -Default '')))
            SubscriptionId = [string](_ARB-GetProp -Obj $_ -Name 'SubscriptionId' -Default '')
            Remediation = Remove-Credentials ([string](_ARB-GetProp -Obj $_ -Name 'Remediation' -Default ''))
        }
    })

    $formatsSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Formats | ForEach-Object { ([string]$_).ToLowerInvariant() }))

    if ($formatsSet.Contains('json')) {
        $jsonPath = Join-Path $evidenceDir 'findings-all.json'
        $safeJson = Remove-Credentials ($safeRows | ConvertTo-Json -Depth 20)
        Set-Content -LiteralPath $jsonPath -Value $safeJson -Encoding UTF8
        $written.Add($jsonPath)
    }

    if ($formatsSet.Contains('csv')) {
        $csvPath = Join-Path $evidenceDir 'findings-all.csv'
        $safeRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        $written.Add($csvPath)

        $bySubDir = Join-Path $evidenceDir 'findings-by-subscription'
        if (-not (Test-Path -LiteralPath $bySubDir)) { New-Item -ItemType Directory -Path $bySubDir -Force | Out-Null }
        foreach ($grp in @($safeRows | Group-Object -Property SubscriptionId)) {
            if ([string]::IsNullOrWhiteSpace([string]$grp.Name)) { continue }
            $safeSub = ([string]$grp.Name -replace '[^A-Za-z0-9._-]','_')
            $subCsv = Join-Path $bySubDir "$safeSub.csv"
            $grp.Group | Export-Csv -LiteralPath $subCsv -NoTypeInformation -Encoding UTF8
            $written.Add($subCsv)
        }

        $byFwDir = Join-Path $evidenceDir 'findings-by-framework'
        if (-not (Test-Path -LiteralPath $byFwDir)) { New-Item -ItemType Directory -Path $byFwDir -Force | Out-Null }
        foreach ($fw in @('CIS','NIST','MCSB','ISO27001')) {
            $subset = @($Findings | Where-Object {
                @(_ARB-ExtractMappings -Finding $_ | Where-Object { (_ARB-CanonicalFramework $_.Framework) -eq $fw }).Count -gt 0
            } | ForEach-Object {
                [pscustomobject]@{
                    Id = [string](_ARB-GetProp -Obj $_ -Name 'Id' -Default '')
                    Source = [string](_ARB-GetProp -Obj $_ -Name 'Source' -Default '')
                    Severity = [string](_ARB-GetProp -Obj $_ -Name 'Severity' -Default '')
                    Title = Remove-Credentials ([string](_ARB-GetProp -Obj $_ -Name 'Title' -Default ''))
                    EntityId = Remove-Credentials ([string](_ARB-GetProp -Obj $_ -Name 'EntityId' -Default (_ARB-GetProp -Obj $_ -Name 'ResourceId' -Default '')))
                }
            })
            $fwCsv = Join-Path $byFwDir "$fw.csv"
            $subset | Export-Csv -LiteralPath $fwCsv -NoTypeInformation -Encoding UTF8
            $written.Add($fwCsv)
        }
    }

    if ($formatsSet.Contains('xlsx') -and (Get-Command Export-Excel -ErrorAction SilentlyContinue)) {
        $xlsxPath = Join-Path $evidenceDir 'findings-all.xlsx'
        $safeRows | Export-Excel -Path $xlsxPath -WorksheetName 'Findings' -AutoSize -TableName 'Findings' | Out-Null
        $written.Add($xlsxPath)
    }

    $citationPath = Join-Path $evidenceDir 'citations.txt'
    $citations = @($Findings | ForEach-Object { New-AuditorCitation -Finding $_ -Style 'workpaper' })
    Set-Content -LiteralPath $citationPath -Value (Remove-Credentials ($citations -join [Environment]::NewLine)) -Encoding UTF8
    $written.Add($citationPath)

    return $written.ToArray()
}

function Write-AuditorRenderTier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Context,
        [Parameter(Mandatory)] [string]    $OutputDirectory,
        [Parameter(Mandatory)]
        [ValidateSet('PureJson','EmbeddedSqlite','SidecarSqlite','PodeViewer')]
        [string] $Tier
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

    $htmlPath = Join-Path $OutputDirectory 'audit-report.html'
    $mdPath = Join-Path $OutputDirectory 'audit-report.md'

    $summary = $Context.ExecutiveSummary
    $controls = @($Context.ControlSections)
    $degradations = @($Context.Degradations)

    $degradeBanner = if ($degradations.Count -gt 0) {
        "<div class='warn'><strong>Declared degradations:</strong> " + (($degradations | ForEach-Object { "$(Remove-Credentials ([string]$_.sectionId)) → $(Remove-Credentials ([string]$_.thisTierMode))" }) -join '; ') + "</div>"
    } else {
        ''
    }

    $controlHtml = @($controls | ForEach-Object {
        $rows = @($_.controls | Select-Object -First 20 | ForEach-Object {
            "<tr><td>$(Remove-Credentials ([string]$_.id))</td><td>$(Remove-Credentials ([string]$_.status))</td><td>$([int]$_.findingCount)</td><td>$(Remove-Credentials ([string]$_.severityRollup))</td></tr>"
        }) -join "`n"

        "<section><h2>$($_.framework) coverage</h2><p>pass: $($_.coverageBar.pass) · fail: $($_.coverageBar.fail)</p><table><thead><tr><th>Control</th><th>Status</th><th>Findings</th><th>Severity</th></tr></thead><tbody>$rows</tbody></table></section>"
    }) -join "`n"

    if ($Tier -in @('SidecarSqlite','PodeViewer')) {
        $controlHtml = @($controls | ForEach-Object {
            "<section><h2>$($_.framework) coverage</h2><p>Rendering mode: $(($Context.Sections | Where-Object { $_.id -like 'control.*' } | Select-Object -First 1).renderingMode). Open viewer for drill-down.</p></section>"
        }) -join "`n"
    }

    $html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Audit Report</title>
<style>
:root{color-scheme:light dark}body{font-family:Segoe UI,Arial,sans-serif;max-width:1180px;margin:0 auto;padding:24px;line-height:1.4}header{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}h1{margin:0}.badge{font-size:12px;padding:2px 8px;border-radius:999px;border:1px solid #999}.warn{margin:16px 0;padding:10px 12px;background:#fff5d6;border:1px solid #f0ce78;border-radius:8px}table{width:100%;border-collapse:collapse;margin-top:8px}th,td{border:1px solid #cfcfcf;padding:6px 8px;text-align:left}section{margin-top:20px}pre{white-space:pre-wrap}@media print{a::after{content:" (" attr(href) ")"} .warn{background:#fff}}</style>
</head>
<body>
<header>
  <h1>Azure Analyzer Audit Report <span class='badge'>$Tier</span></h1>
  <div>Generated $(Get-Date -Format o)</div>
</header>
$degradeBanner
<section>
  <h2>Executive Summary</h2>
  <p>$(Remove-Credentials ([string]$summary.scopeStatement))</p>
  <p>$(Remove-Credentials ([string]$summary.methodology))</p>
  <p>Severity: Critical $($summary.severityCounts.Critical), High $($summary.severityCounts.High), Medium $($summary.severityCounts.Medium), Low $($summary.severityCounts.Low), Info $($summary.severityCounts.Info).</p>
</section>
$controlHtml
<section>
  <h2>Attack Paths</h2>
  <p>Mode: $(Remove-Credentials ([string]$Context.AttackPathSection.renderingMode)) · Path count: $($Context.AttackPathSection.pathCount)</p>
</section>
<section>
  <h2>Resilience</h2>
  <p>Mode: $(Remove-Credentials ([string]$Context.ResilienceSection.renderingMode)) · Blast radius edges: $($Context.ResilienceSection.blastRadius)</p>
</section>
<section>
  <h2>Policy Coverage</h2>
  <p>Assigned: $($Context.PolicyCoverageSection.assignedVsReference.assigned) / Reference: $($Context.PolicyCoverageSection.assignedVsReference.reference) · Gaps: $($Context.PolicyCoverageSection.gapCount)</p>
</section>
<section>
  <h2>Ready to Remediate</h2>
  <ul>
$(($Context.RemediationAppendix.groupsByRemediation | Select-Object -First 20 | ForEach-Object { "    <li><strong>$(Remove-Credentials ([string]$_.remediation))</strong> ($([int]$_.findingCount), $($_.severityRollup))</li>" }) -join "`n")
  </ul>
</section>
<section>
  <h2>Evidence Export</h2>
  <ul>
$(($Context.EvidenceFiles | ForEach-Object { "    <li><a href='$(Split-Path -Leaf $_)'>$(Split-Path -Leaf $_)</a></li>" }) -join "`n")
  </ul>
</section>
</body>
</html>
"@

    $md = @"
# Azure Analyzer Audit Report ($Tier)

$(if ($degradations.Count -gt 0) { "**Declared degradations:** " + (($degradations | ForEach-Object { "`$($_.sectionId) => $($_.thisTierMode)" }) -join ', ') } else { "**Declared degradations:** none" })

## Executive Summary

- Scope: $(Remove-Credentials ([string]$summary.scopeStatement))
- Methodology: $(Remove-Credentials ([string]$summary.methodology))
- Severity: Critical $($summary.severityCounts.Critical), High $($summary.severityCounts.High), Medium $($summary.severityCounts.Medium), Low $($summary.severityCounts.Low), Info $($summary.severityCounts.Info)

## Control Domains

$(($controls | ForEach-Object { "### $($_.framework)`n- Controls: $(@($_.controls).Count)`n- Fail: $($_.coverageBar.fail)`n- Pass: $($_.coverageBar.pass)" }) -join "`n`n")

## Attack Paths

- Mode: $(Remove-Credentials ([string]$Context.AttackPathSection.renderingMode))
- Path count: $($Context.AttackPathSection.pathCount)

## Resilience

- Mode: $(Remove-Credentials ([string]$Context.ResilienceSection.renderingMode))
- Blast radius edges: $($Context.ResilienceSection.blastRadius)

## Policy Coverage

- Assigned: $($Context.PolicyCoverageSection.assignedVsReference.assigned)
- Reference: $($Context.PolicyCoverageSection.assignedVsReference.reference)
- Gaps: $($Context.PolicyCoverageSection.gapCount)

## Ready to Remediate

$(($Context.RemediationAppendix.groupsByRemediation | Select-Object -First 20 | ForEach-Object { "- $(Remove-Credentials ([string]$_.remediation)) ($([int]$_.findingCount), $($_.severityRollup))" }) -join "`n")

## Evidence Export

$(($Context.EvidenceFiles | ForEach-Object { "- $(Split-Path -Leaf $_)" }) -join "`n")
"@

    Set-Content -LiteralPath $htmlPath -Value (Remove-Credentials $html) -Encoding UTF8
    Set-Content -LiteralPath $mdPath -Value (Remove-Credentials $md) -Encoding UTF8

    return @($htmlPath, $mdPath)
}

function New-AuditorCitation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Finding,
        [ValidateSet('inline','footnote','workpaper')] [string] $Style = 'workpaper'
    )

    $source = [string](_ARB-GetProp -Obj $Finding -Name 'Source' -Default 'unknown')
    $pin = [string](_ARB-GetProp -Obj $Finding -Name 'ToolVersion' -Default (_ARB-GetProp -Obj $Finding -Name 'SourceVersion' -Default 'v?'))
    $id = [string](_ARB-GetProp -Obj $Finding -Name 'Id' -Default 'unknown-id')
    $title = [string](_ARB-GetProp -Obj $Finding -Name 'Title' -Default 'untitled')
    $resource = [string](_ARB-GetProp -Obj $Finding -Name 'EntityId' -Default (_ARB-GetProp -Obj $Finding -Name 'ResourceId' -Default 'n/a'))
    $severity = _ARB-SeverityLabel ([string](_ARB-GetProp -Obj $Finding -Name 'Severity' -Default 'Info'))
    $collected = [string](_ARB-GetProp -Obj $Finding -Name 'ObservedAtUtc' -Default (_ARB-GetProp -Obj $Finding -Name 'CollectedAt' -Default (Get-Date).ToUniversalTime().ToString('o')))
    $rule = [string](_ARB-GetProp -Obj $Finding -Name 'DeepLinkUrl' -Default '')
    $docs = [string](_ARB-GetProp -Obj $Finding -Name 'LearnMoreUrl' -Default '')
    $queryHash = [string](_ARB-GetProp -Obj $Finding -Name 'SourceQueryHash' -Default '')

    $base = "[$source $pin] ${id}: $title. Resource: $resource. Severity: $severity. Collected $collected."
    if (-not [string]::IsNullOrWhiteSpace($rule)) { $base += " Rule: $rule." }
    if (-not [string]::IsNullOrWhiteSpace($docs)) { $base += " Docs: $docs." }
    if (-not [string]::IsNullOrWhiteSpace($queryHash)) { $base += " QueryHash: $queryHash." }

    switch ($Style) {
        'inline' { return (Remove-Credentials $base) }
        'footnote' { return (Remove-Credentials "[$id] $base") }
        default { return (Remove-Credentials $base) }
    }
}

function Build-AuditorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InputPath,
        [Parameter(Mandatory)] [string] $EntitiesPath,
        [Parameter(Mandatory)] [string] $ManifestPath,
        [string]   $TriagePath = '',
        [string]   $PreviousRunPath = '',
        [Parameter(Mandatory)] [string] $OutputDirectory,
        [ValidateSet('auditor')] [string] $Profile = 'auditor',
        [string[]] $ControlFrameworks = @('CIS','NIST','MCSB','ISO27001'),
        [ValidateSet('PureJson','EmbeddedSqlite','SidecarSqlite','PodeViewer')]
        [string]   $Tier,
        [ValidateSet('inline','footnote','workpaper')] [string] $CitationStyle = 'workpaper',
        [switch]   $PassThru
    )

    $context = Resolve-AuditorContext -InputPath $InputPath -EntitiesPath $EntitiesPath -ManifestPath $ManifestPath -TriagePath $TriagePath -PreviousRunPath $PreviousRunPath -Tier $Tier

    $sectionCatalog = _ARB-SectionCatalog -Tier $context.Tier -Frameworks $ControlFrameworks
    $exec = Get-AuditorExecutiveSummary -Findings $context.Findings -PreviousFindings $context.PreviousFindings -ControlFrameworks $ControlFrameworks
    $controlSections = Get-AuditorControlDomainSections -Findings $context.Findings -Frameworks $ControlFrameworks
    $attack = Get-AuditorAttackPathSection -Entities ([pscustomobject]@{ Entities = $context.Entities; Edges = $context.Edges }) -Tier $context.Tier
    $resilience = Get-AuditorResilienceSection -Entities ([pscustomobject]@{ Entities = $context.Entities; Edges = $context.Edges }) -Tier $context.Tier
    $policy = Get-AuditorPolicyCoverageSection -Entities ([pscustomobject]@{ Entities = $context.Entities; Edges = $context.Edges }) -Findings $context.Findings
    $triage = Get-AuditorTriageAnnotations -Findings $context.Findings -TriagePath $TriagePath
    $remediation = Get-AuditorRemediationAppendix -Findings $context.Findings
    $evidenceFiles = Get-AuditorEvidenceExport -Findings $context.Findings -OutputDirectory $OutputDirectory -Formats @('csv','json','xlsx')

    $renderContext = @{
        Tier = $context.Tier
        ExecutiveSummary = $exec
        ControlSections = @($controlSections)
        AttackPathSection = $attack
        ResilienceSection = $resilience
        PolicyCoverageSection = $policy
        TriageAnnotations = $triage
        RemediationAppendix = $remediation
        EvidenceFiles = @($evidenceFiles)
        Sections = @($sectionCatalog.Sections)
        Degradations = @($sectionCatalog.Degradations)
    }

    $renderedPaths = Write-AuditorRenderTier -Context $renderContext -OutputDirectory $OutputDirectory -Tier $context.Tier

    $manifest = $context.Manifest
    if ($null -eq $manifest) { $manifest = [pscustomobject]@{} }
    if (-not (_ARB-HasProp -Obj $manifest -Name 'report')) {
        $manifest | Add-Member -NotePropertyName 'report' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not (_ARB-HasProp -Obj $manifest.report -Name 'profile')) {
        $manifest.report | Add-Member -NotePropertyName 'profile' -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $auditorBlock = [pscustomobject]@{
        schemaVersion = '1.0'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        runId = $context.RunId
        previousRunId = if ($context.PreviousFindings.Count -gt 0) { 'previous-run' } else { '' }
        controlFrameworks = @($ControlFrameworks)
        scopeStatement = [string]$exec.scopeStatement
        methodology = [string]$exec.methodology
        outputs = [pscustomobject]@{
            html = 'audit-report.html'
            md = 'audit-report.md'
            evidenceDir = 'audit-evidence/'
        }
        sections = @($sectionCatalog.Sections)
        degradations = @($sectionCatalog.Degradations)
    }

    $manifest.report | Add-Member -NotePropertyName 'manifestVersion' -NotePropertyValue '1.0' -Force
    $manifest.report | Add-Member -NotePropertyName 'tier' -NotePropertyValue $context.Tier -Force
    $manifest.report.profile | Add-Member -NotePropertyName 'auditor' -NotePropertyValue $auditorBlock -Force

    $manifestJson = Remove-Credentials ($manifest | ConvertTo-Json -Depth 60)
    Set-Content -LiteralPath $ManifestPath -Value $manifestJson -Encoding UTF8

    $result = [pscustomobject]@{
        Tier = $context.Tier
        HtmlPath = Join-Path $OutputDirectory 'audit-report.html'
        MdPath = Join-Path $OutputDirectory 'audit-report.md'
        EvidenceDirectory = Join-Path $OutputDirectory 'audit-evidence'
        EvidenceFiles = @($evidenceFiles)
        Sections = @($sectionCatalog.Sections)
        Degradations = @($sectionCatalog.Degradations)
        CitationStyle = $CitationStyle
    }

    if ($PassThru) {
        $result | Add-Member -NotePropertyName 'Context' -NotePropertyValue $renderContext -Force
    }

    return $result
}
