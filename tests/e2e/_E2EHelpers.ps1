#Requires -Version 7.4
<#
.SYNOPSIS
    E2E pipeline driver for the Invoke-AzureAnalyzer harness.

.DESCRIPTION
    Exercises the same output pipeline that Invoke-AzureAnalyzer.ps1 runs after
    wrappers emit findings: New-FindingRow -> EntityStore -> results.json /
    entities.json (credential-scrubbed) -> New-HtmlReport -> New-MdReport.

    Designed to run without touching real Azure / Graph / GitHub. Each test
    context feeds synthetic, per-surface findings into this helper and asserts
    on the emitted artifacts. Mirrors the orchestrator's write block at
    Invoke-AzureAnalyzer.ps1:1328-1362.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-E2EFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RuleId,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $EntityId,
        [Parameter(Mandatory)] [string] $EntityType,
        [Parameter(Mandatory)] [bool]   $Compliant,
        [string] $Severity = 'Info',
        [string] $Category = '',
        [string] $Detail = '',
        [string] $Remediation = '',
        [string] $ResourceId = '',
        [string] $LearnMoreUrl = '',
        [string] $Platform = '',
        [string] $SubscriptionId = '',
        [string] $ResourceGroup = '',
        [string] $Pillar = '',
        [string] $RunId = 'e2e-run'
    )

    $params = @{
        Id              = [guid]::NewGuid().ToString()
        Source          = $Source
        EntityId        = $EntityId
        EntityType      = $EntityType
        Title           = $Title
        RuleId          = $RuleId
        Compliant       = $Compliant
        ProvenanceRunId = $RunId
        Severity        = $Severity
    }
    if ($Category)       { $params.Category       = $Category }
    if ($Detail)         { $params.Detail         = $Detail }
    if ($Remediation)    { $params.Remediation    = $Remediation }
    if ($ResourceId)     { $params.ResourceId     = $ResourceId }
    if ($LearnMoreUrl)   { $params.LearnMoreUrl   = $LearnMoreUrl }
    if ($Platform)       { $params.Platform       = $Platform }
    if ($SubscriptionId) { $params.SubscriptionId = $SubscriptionId }
    if ($ResourceGroup)  { $params.ResourceGroup  = $ResourceGroup }
    if ($Pillar)         { $params.Pillar         = $Pillar }

    return New-FindingRow @params
}

function Invoke-E2EPipeline {
    <#
    .SYNOPSIS
        Run the orchestrator's output + report stage against a prepared finding set.
    .PARAMETER Findings
        Array of FindingRow objects built via New-FindingRow (or New-E2EFinding).
    .PARAMETER OutputPath
        Directory to write results.json, entities.json, report.html, report.md.
    .PARAMETER Edges
        Optional v3 edges to include in entities.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [Parameter(Mandatory)] [string]   $OutputPath,
        [object[]] $Edges = @(),
        [switch] $SkipReports
    )

    if (-not (Test-Path $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }

    $store = [EntityStore]::new(50000, $OutputPath)
    foreach ($f in $Findings) {
        if ($null -eq $f) { continue }
        $store.AddFinding($f)
    }
    foreach ($e in $Edges) {
        if ($null -eq $e) { continue }
        try { $store.AddEdge([pscustomobject]$e) } catch { }
    }

    $v1Results = foreach ($f in (Export-Findings -Store $store)) {
        [PSCustomObject]@{
            Id             = $f.Id
            Source         = $f.Source
            Category       = if ($f.PSObject.Properties['Category']) { $f.Category } else { '' }
            Title          = $f.Title
            Severity       = if ($f.PSObject.Properties['Severity'] -and $f.Severity) { $f.Severity } else { 'Info' }
            Compliant      = $f.Compliant
            Detail         = if ($f.PSObject.Properties['Detail']) { $f.Detail } else { '' }
            Remediation    = if ($f.PSObject.Properties['Remediation']) { $f.Remediation } else { '' }
            ResourceId     = if ($f.PSObject.Properties['ResourceId']) { $f.ResourceId } else { '' }
            LearnMoreUrl   = if ($f.PSObject.Properties['LearnMoreUrl']) { $f.LearnMoreUrl } else { '' }
            EntityId       = $f.EntityId
            EntityType     = $f.EntityType
            Platform       = if ($f.PSObject.Properties['Platform']) { $f.Platform } else { '' }
            SubscriptionId = if ($f.PSObject.Properties['SubscriptionId']) { $f.SubscriptionId } else { '' }
            ResourceGroup  = if ($f.PSObject.Properties['ResourceGroup']) { $f.ResourceGroup } else { '' }
            Frameworks     = if ($f.PSObject.Properties['Frameworks']) { $f.Frameworks } else { @() }
            Controls       = if ($f.PSObject.Properties['Controls']) { $f.Controls } else { @() }
            SchemaVersion  = if ($f.PSObject.Properties['SchemaVersion']) { $f.SchemaVersion } else { '2.2' }
        }
    }
    $v1Results = @($v1Results)

    $resultsFile = Join-Path $OutputPath 'results.json'
    $resultsJson = if ($v1Results.Count -eq 0) { '[]' } else { $v1Results | ConvertTo-Json -Depth 10 }
    Set-Content -Path $resultsFile -Value (Remove-Credentials $resultsJson) -Encoding UTF8

    $entities = @(Export-Entities -Store $store)
    $storeEdges = @()
    if (Get-Command Export-Edges -ErrorAction SilentlyContinue) {
        $storeEdges = @(Export-Edges -Store $store)
    }

    $entitiesPayload = [PSCustomObject]@{
        SchemaVersion = '3.1'
        Entities      = $entities
        Edges         = $storeEdges
    }
    $entitiesFile = Join-Path $OutputPath 'entities.json'
    $entitiesJson = $entitiesPayload | ConvertTo-Json -Depth 30
    Set-Content -Path $entitiesFile -Value (Remove-Credentials $entitiesJson) -Encoding UTF8

    $htmlFile = Join-Path $OutputPath 'report.html'
    $mdFile   = Join-Path $OutputPath 'report.md'
    if (-not $SkipReports) {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        & (Join-Path $repoRoot 'New-HtmlReport.ps1') -InputPath $resultsFile -OutputPath $htmlFile | Out-Null
        & (Join-Path $repoRoot 'New-MdReport.ps1')   -InputPath $resultsFile -OutputPath $mdFile   | Out-Null
    }

    return [pscustomobject]@{
        OutputPath   = $OutputPath
        ResultsFile  = $resultsFile
        EntitiesFile = $entitiesFile
        HtmlFile     = $htmlFile
        MdFile       = $mdFile
        Findings     = $v1Results
        Entities     = $entities
        Edges        = $storeEdges
    }
}

function Assert-NoPlantedSecrets {
    <#
    .SYNOPSIS
        Assert planted secrets never appear in any output file produced by the pipeline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Files,
        [Parameter(Mandatory)] [string[]] $PlantedLiterals
    )

    foreach ($file in $Files) {
        if (-not (Test-Path $file)) { continue }
        $content = Get-Content -Path $file -Raw -ErrorAction Stop
        foreach ($literal in $PlantedLiterals) {
            if ($content -like "*$literal*") {
                throw "E2E scrub guard: planted literal '$literal' LEAKED into output file '$file'."
            }
        }
    }
}
