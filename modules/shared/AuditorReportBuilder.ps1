#Requires -Version 7.4
<#
.SYNOPSIS
    Auditor-driven report builder (Track F / issue #434) - SKELETON ONLY.

.DESCRIPTION
    Track F redesigns azure-analyzer's report from a finding-centric view
    into a control-centric, auditor-grade view: audit-style executive
    summary, per-control-domain sections (CIS, NIST, MCSB, ISO 27001),
    "Ready to remediate" appendix grouped by Remediation, evidence export,
    and diff vs. previous run.

    THIS FILE IS A SKELETON. Every public function throws
    [System.NotImplementedException]. Implementation is held until the
    dependency tracks land:

      - Track A (#428) - attack paths
      - Track B (#429) - resilience / blast-radius
      - Track C (#431) - policy coverage vs. ALZ reference
      - Track D (#432) - tool-output fidelity (ComplianceMappings, Pillar,
                         Impact, Effort, RemediationSnippets, DeepLinkUrl)
      - Track E (#433 / #466 / #462) - LLM triage verdicts
      - Track V (#430 / #467) + foundation (#435) - tier picker and
                         report-manifest.json schema

    Function signatures here are FROZEN by the design doc at
    docs/design/track-f-auditor-redesign.md. A future implementation PR
    fills the bodies, drops the -Skip placeholders on the tests, and
    flips the wire-up in Invoke-AzureAnalyzer.ps1 (-Profile Auditor).

    Pester baseline is preserved by this skeleton (no callers, no tests
    other than the skip-placeholders that assert NotImplementedException).

.NOTES
    See docs/design/track-f-auditor-redesign.md for the full architecture,
    layout sketches, mock JSON shapes, tier matrix, and test strategy.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AuditorReportBuilderVersion = '0.0.1-skeleton'

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
    throw [System.NotImplementedException]::new(
        'Build-AuditorReport: Track F is design-only until Tracks A-E + V land. See docs/design/track-f-auditor-redesign.md.')
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
    
    $findings = Get-Content -Path $InputPath -Raw | ConvertFrom-Json
    $entities = Get-Content -Path $EntitiesPath -Raw | ConvertFrom-Json
    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    
    $resolvedTier = if ($manifest.tier) { $manifest.tier } else { $Tier }
    
    $frameworks = if ($manifest.profile.auditor.frameworks) {
        $manifest.profile.auditor.frameworks
    } else {
        @('CIS', 'NIST', 'MCSB', 'ISO27001')
    }
    
    $context = @{
        Findings = $findings
        Entities = $entities
        Manifest = $manifest
        Tier = $resolvedTier
        Frameworks = $frameworks
    }
    
    if ($TriagePath -and (Test-Path $TriagePath)) {
        $context.TriageData = Get-Content -Path $TriagePath -Raw | ConvertFrom-Json
    }
    
    if ($PreviousRunPath -and (Test-Path $PreviousRunPath)) {
        $context.PreviousFindings = Get-Content -Path $PreviousRunPath -Raw | ConvertFrom-Json
    }
    
    return $context
}

function Get-AuditorExecutiveSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [object[]] $PreviousFindings = @(),
        [string[]] $ControlFrameworks = @('CIS','NIST','MCSB','ISO27001')
    )
    
    $severityGroups = $Findings | Group-Object -Property Severity
    $severityCounts = @{}
    foreach ($group in $severityGroups) {
        $severityCounts[$group.Name] = $group.Count
    }
    
    $frameworkCoverage = @{}
    foreach ($framework in $ControlFrameworks) {
        $totalFindings = $Findings.Count
        $covered = 0
        
        foreach ($finding in $Findings) {
            if ($finding.ComplianceMappings) {
                foreach ($mapping in $finding.ComplianceMappings) {
                    if ($mapping -match "^$framework\s") {
                        $covered++
                        break
                    }
                }
            }
        }
        
        $pct = if ($totalFindings -gt 0) {
            [math]::Round(($covered / $totalFindings) * 100, 1)
        } else {
            0
        }
        
        $frameworkCoverage[$framework] = @{
            covered = $covered
            total = $totalFindings
            pct = $pct
        }
    }
    
    $summary = @{
        severityCounts = $severityCounts
        frameworkCoverage = $frameworkCoverage
        collectedAt = (Get-Date).ToUniversalTime().ToString('o')
        scope = 'Tenant scope placeholder'
    }
    
    if ($PreviousFindings.Count -gt 0) {
        $currentIds = $Findings | ForEach-Object { $_.FindingId } | Where-Object { $_ }
        $previousIds = $PreviousFindings | ForEach-Object { $_.FindingId } | Where-Object { $_ }
        
        $added = ($currentIds | Where-Object { $_ -notin $previousIds }).Count
        $resolved = ($previousIds | Where-Object { $_ -notin $currentIds }).Count
        
        $changedSeverity = 0
        $currentLookup = @{}
        foreach ($f in $Findings) {
            if ($f.FindingId) {
                $currentLookup[$f.FindingId] = $f.Severity
            }
        }
        
        foreach ($prevFinding in $PreviousFindings) {
            if ($prevFinding.FindingId -and $currentLookup.ContainsKey($prevFinding.FindingId)) {
                if ($prevFinding.Severity -ne $currentLookup[$prevFinding.FindingId]) {
                    $changedSeverity++
                }
            }
        }
        
        $summary.diffSummary = @{
            added = $added
            resolved = $resolved
            changedSeverity = $changedSeverity
        }
    }
    
    return $summary
}

function Get-AuditorControlDomainSections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [string[]] $Frameworks = @('CIS','NIST','MCSB','ISO27001')
    )
    
    $sections = @()
    
    foreach ($framework in $Frameworks) {
        $controlGroups = @{}
        
        foreach ($finding in $Findings) {
            $mappings = if ($finding.PSObject.Properties['ComplianceMappings']) { $finding.ComplianceMappings } else { $null }
            if (-not $mappings) { continue }
            
            foreach ($mapping in $mappings) {
                if ([string]::IsNullOrWhiteSpace($mapping)) { continue }
                
                $mappingStr = [string]$mapping
                if ($mappingStr -match "^$framework\s+(.+)$") {
                    $controlId = $Matches[1].Trim()
                    
                    if (-not $controlGroups.ContainsKey($controlId)) {
                        $controlGroups[$controlId] = @()
                    }
                    $controlGroups[$controlId] += $finding
                }
            }
        }
        
        foreach ($controlId in ($controlGroups.Keys | Sort-Object)) {
            $findingsList = $controlGroups[$controlId]
            $sections += [PSCustomObject]@{
                Framework = $framework
                ControlId = $controlId
                FindingCount = $findingsList.Count
                Findings = @($findingsList)
            }
        }
    }
    
    return $sections
}

function ConvertTo-AuditorControlDomainSectionsHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Sections
    )
    
    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<div class="control-domain-sections">')
    
    $groupedByFramework = $Sections | Group-Object -Property Framework
    
    foreach ($fwGroup in $groupedByFramework) {
        [void]$html.AppendLine("<h3>$($fwGroup.Name)</h3>")
        [void]$html.AppendLine('<table class="control-domain-table">')
        [void]$html.AppendLine('<thead><tr><th>Control ID</th><th>Finding Count</th></tr></thead>')
        [void]$html.AppendLine('<tbody>')
        
        foreach ($section in ($fwGroup.Group | Sort-Object ControlId)) {
            [void]$html.AppendLine("<tr><td>$($section.ControlId)</td><td>$($section.FindingCount)</td></tr>")
        }
        
        [void]$html.AppendLine('</tbody></table>')
    }
    
    [void]$html.AppendLine('</div>')
    return $html.ToString()
}

function ConvertTo-AuditorControlDomainSectionsMd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Sections
    )
    
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine('## Control Domain Sections')
    [void]$md.AppendLine()
    
    $groupedByFramework = $Sections | Group-Object -Property Framework
    
    foreach ($fwGroup in $groupedByFramework) {
        [void]$md.AppendLine("### $($fwGroup.Name)")
        [void]$md.AppendLine()
        [void]$md.AppendLine('| Control ID | Finding Count |')
        [void]$md.AppendLine('|------------|---------------|')
        
        foreach ($section in ($fwGroup.Group | Sort-Object ControlId)) {
            [void]$md.AppendLine("| $($section.ControlId) | $($section.FindingCount) |")
        }
        
        [void]$md.AppendLine()
    }
    
    return $md.ToString()
}

function Get-AuditorAttackPathSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entities,
        [Parameter(Mandatory)] [string] $Tier
    )
    
    $attackPathEdges = @()
    $criticalPaths = 0
    
    if ($Entities.PSObject.Properties['edges']) {
        $attackPathRelations = @('HasFederatedCredential', 'AuthenticatesAs', 'UsesSecret', 'HasRoleOn', 'DeploysTo', 'TriggeredBy')
        
        foreach ($edge in $Entities.edges) {
            if ($null -eq $edge) { continue }
            $relation = if ($edge.PSObject.Properties['relation']) { [string]$edge.relation } else { '' }
            
            if ($relation -in $attackPathRelations) {
                $attackPathEdges += $edge
                
                $criticality = ''
                if ($edge.PSObject.Properties['metadata'] -and $edge.metadata.PSObject.Properties['attackPathCriticality']) {
                    $criticality = [string]$edge.metadata.attackPathCriticality
                }
                if ($criticality -ieq 'Critical') {
                    $criticalPaths++
                }
            }
        }
    }
    
    $renderingMode = switch ($Tier) {
        'PureJson' { 'inline' }
        'EmbeddedSqlite' { 'inline' }
        'SidecarSqlite' { 'paginated' }
        'PodeViewer' { 'deepLink' }
        default { 'inline' }
    }
    
    $result = @{
        RenderingMode = $renderingMode
        TotalPaths = $attackPathEdges.Count
        CriticalPaths = $criticalPaths
        HtmlSnippet = $null
        DeepLinkUrl = $null
    }
    
    if ($renderingMode -eq 'deepLink') {
        $result.DeepLinkUrl = '/viewer/attack-paths'
    } elseif ($renderingMode -eq 'inline' -and $attackPathEdges.Count -gt 0) {
        $result.HtmlSnippet = "<div class='attack-path-graph'><p>Cytoscape graph placeholder: $($attackPathEdges.Count) attack paths</p></div>"
    }
    
    return $result
}

function Get-AuditorResilienceSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entities,
        [Parameter(Mandatory)] [string] $Tier
    )
    
    $resourcesWithScores = @()
    $totalEntities = 0
    
    foreach ($key in $Entities.PSObject.Properties.Name) {
        $entity = $Entities.$key
        if ($null -eq $entity) { continue }
        if ($key -eq 'edges' -or $key -eq 'policyGaps') { continue }
        
        $totalEntities++
        
        if ($entity.PSObject.Properties['properties'] -and 
            $entity.properties.PSObject.Properties['blastRadiusScore']) {
            $score = [double]$entity.properties.blastRadiusScore
            $displayName = if ($entity.PSObject.Properties['displayName']) { [string]$entity.displayName } else { $key }
            
            $resourcesWithScores += [PSCustomObject]@{
                EntityId = $key
                DisplayName = $displayName
                BlastRadiusScore = $score
            }
        }
    }
    
    $topResources = @($resourcesWithScores | Sort-Object -Property BlastRadiusScore -Descending | Select-Object -First 10)
    
    $renderingMode = switch ($Tier) {
        'PureJson' { 'inline' }
        'EmbeddedSqlite' { 'inline' }
        'SidecarSqlite' { 'paginated' }
        'PodeViewer' { 'deepLink' }
        default { 'inline' }
    }
    
    return @{
        RenderingMode = $renderingMode
        TopResources = $topResources
        TotalEntities = $totalEntities
    }
}

function Get-AuditorPolicyCoverageSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entities,
        [Parameter(Mandatory)] [object[]] $Findings
    )
    
    $assignedCount = 0
    $missingCount = 0
    $gapSuggestions = @()
    $azAdvertizerLinks = @()
    
    if ($Entities.PSObject.Properties['policyGaps']) {
        $gaps = @($Entities.policyGaps)
        $missingCount = $gaps.Count
        
        foreach ($gap in $gaps) {
            if ($null -eq $gap) { continue }
            
            $policyId = if ($gap.PSObject.Properties['policyId']) { [string]$gap.policyId } else { '' }
            $displayName = if ($gap.PSObject.Properties['displayName']) { [string]$gap.displayName } else { 'Unknown Policy' }
            $scope = if ($gap.PSObject.Properties['scope']) { [string]$gap.scope } else { '' }
            
            if (-not [string]::IsNullOrWhiteSpace($policyId)) {
                $gapSuggestions += [PSCustomObject]@{
                    PolicyId = $policyId
                    DisplayName = $displayName
                    Scope = $scope
                }
                
                $azAdvertizerLinks += "https://www.azadvertizer.net/azpolicyadvertizer/$policyId.html"
            }
        }
    }
    
    $totalFindings = @($Findings).Count
    if ($totalFindings -gt 0 -and $missingCount -lt $totalFindings) {
        $assignedCount = $totalFindings - $missingCount
    }
    
    return @{
        AssignedCount = $assignedCount
        MissingCount = $missingCount
        GapSuggestions = @($gapSuggestions)
        AzAdvertizerLinks = @($azAdvertizerLinks)
    }
}

function Get-AuditorTriageAnnotations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [string] $TriagePath = ''
    )
    throw [System.NotImplementedException]::new('Get-AuditorTriageAnnotations: requires Track E (#433/#466).')
}

function Get-AuditorRemediationAppendix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings
    )
    
    $sanitizePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'shared' 'Sanitize.ps1'
    if (Test-Path $sanitizePath) { . $sanitizePath }
    
    $remediationGroups = @{}
    
    foreach ($finding in $Findings) {
        if ($null -eq $finding) { continue }
        
        $remediation = if ($finding.PSObject.Properties['Remediation']) { [string]$finding.Remediation } else { '' }
        
        if ([string]::IsNullOrWhiteSpace($remediation)) { continue }
        
        if (-not $remediationGroups.ContainsKey($remediation)) {
            $remediationGroups[$remediation] = @()
        }
        $remediationGroups[$remediation] += $finding
    }
    
    $severityWeights = @{
        'Critical' = 4
        'High' = 3
        'Medium' = 2
        'Low' = 1
        'Info' = 0
    }
    
    $groups = @()
    foreach ($key in $remediationGroups.Keys) {
        $groupFindings = $remediationGroups[$key]
        $maxWeight = 0
        $maxSeverity = 'Info'
        
        foreach ($f in $groupFindings) {
            $sev = if ($f.PSObject.Properties['Severity']) { [string]$f.Severity } else { 'Info' }
            $weight = if ($severityWeights.ContainsKey($sev)) { $severityWeights[$sev] } else { 0 }
            if ($weight -gt $maxWeight) {
                $maxWeight = $weight
                $maxSeverity = $sev
            }
        }
        
        $groups += [PSCustomObject]@{
            RemediationText = $key
            Findings = @($groupFindings)
            TotalCount = $groupFindings.Count
            MaxSeverity = $maxSeverity
            Weight = $maxWeight
        }
    }
    
    $sortedGroups = @($groups | Sort-Object -Property Weight -Descending)
    
    return @{
        RemediationGroups = $sortedGroups
    }
}

function Get-AuditorEvidenceExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [Parameter(Mandatory)] [string]   $OutputDirectory,
        [string[]] $Formats = @('csv','json')
    )
    
    $sanitizePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'shared' 'Sanitize.ps1'
    if (Test-Path $sanitizePath) { . $sanitizePath }
    
    $evidenceDir = Join-Path $OutputDirectory 'audit-evidence'
    if (-not (Test-Path $evidenceDir)) {
        New-Item -Path $evidenceDir -ItemType Directory -Force | Out-Null
    }
    
    $sanitizedFindings = @()
    foreach ($finding in $Findings) {
        if ($null -eq $finding) { continue }
        
        $sanitizedFinding = [PSCustomObject]@{}
        foreach ($prop in $finding.PSObject.Properties) {
            $value = $prop.Value
            if ($value -is [string]) {
                $sanitizedFinding | Add-Member -MemberType NoteProperty -Name $prop.Name -Value (Remove-Credentials -Text $value)
            } else {
                $sanitizedFinding | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $value
            }
        }
        $sanitizedFindings += $sanitizedFinding
    }
    
    $exportedFiles = @()
    
    $csvPath = Join-Path $evidenceDir 'findings.csv'
    $sanitizedFindings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $exportedFiles += $csvPath
    
    $jsonPath = Join-Path $evidenceDir 'findings.json'
    $sanitizedFindings | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
    $exportedFiles += $jsonPath
    
    $importExcelAvailable = $null -ne (Get-Module -ListAvailable -Name ImportExcel)
    if ($importExcelAvailable) {
        $xlsxPath = Join-Path $evidenceDir 'findings.xlsx'
        try {
            $sanitizedFindings | Export-Excel -Path $xlsxPath -AutoSize -TableName 'Findings' -WorksheetName 'Findings' -ErrorAction Stop
            $exportedFiles += $xlsxPath
        } catch {
            Write-Warning "ImportExcel module available but export failed: $_"
        }
    }
    
    return @{
        ExportedFiles = @($exportedFiles)
    }
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
    throw [System.NotImplementedException]::new('Write-AuditorRenderTier: requires Track V (#430) tier contract.')
}

function New-AuditorCitation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Finding,
        [ValidateSet('inline','footnote','workpaper')] [string] $Style = 'workpaper'
    )
    throw [System.NotImplementedException]::new('New-AuditorCitation: skeleton only.')
}
