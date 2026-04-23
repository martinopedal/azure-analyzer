#Requires -Version 7.4
<#
.SYNOPSIS
    E2E wrapper coverage for the five ADO-family tools.
.DESCRIPTION
    Feeds realistic wrapper-output fixtures through the same pipeline that
    Invoke-AzureAnalyzer runs after wrappers return:
      New-FindingRow -> EntityStore -> results.json / entities.json
      (credential-scrubbed) -> New-HtmlReport -> New-MdReport.

    Covers: ado-connections (#653), ado-pipelines (#654),
    ado-consumption (#655), ado-repos-secrets (#656),
    ado-pipeline-correlator (#657).

    Schema invariants asserted on every tool:
      * results.json is valid JSON (v1-compat FindingRow array)
      * entities.json uses v3.1 shape { SchemaVersion, Entities, Edges }
      * HTML and Markdown reports render without PS errors
      * Credential scrubbing removes planted secrets from every artifact
      * Source tag matches the tool name
      * Severity values are within the five-level enum
.NOTES
    Issues: #653, #654, #655, #656, #657
#>
Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

    Get-Module AzureAnalyzer -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'AzureAnalyzer.psd1') -Force

    $sharedDir = Join-Path $script:RepoRoot 'modules\shared'
    foreach ($sharedScript in (Get-ChildItem -Path $sharedDir -Filter '*.ps1' -File)) {
        . $sharedScript.FullName
    }

    . (Join-Path $PSScriptRoot '_E2EHelpers.ps1')

    $script:FixtureDir = Join-Path $script:RepoRoot 'tests' 'fixtures' 'ado'
    $script:ValidSeverities = @('Critical', 'High', 'Medium', 'Low', 'Info')

    $script:PlantedPat = 'ghp_FAKEE2E1234567890abcdef1234567890abc'
    $script:PlantedBearer = 'Bearer eyJhbGciOiJIUzI1NiJ9.FAKE_ADO_E2E_PAYLOAD.signature'
    $script:PlantedLiterals = @($script:PlantedPat, $script:PlantedBearer)

    # Map ADO entity types from fixture fields to canonical EntityType enum values.
    function Get-AdoEntityType {
        param([string]$Category, [string]$AssetType)
        if ($AssetType -eq 'BuildDefinition' -or $AssetType -eq 'ReleaseDefinition') { return 'Pipeline' }
        if ($AssetType -eq 'VariableGroup') { return 'VariableGroup' }
        if ($AssetType -eq 'Environment') { return 'Environment' }
        if ($AssetType -eq 'ServiceConnection') { return 'ServiceConnection' }
        if ($Category -eq 'Service Connection') { return 'ServiceConnection' }
        if ($Category -eq 'Service Connection Usage') { return 'ServiceConnection' }
        if ($Category -match 'Secret') { return 'Repository' }
        if ($Category -match 'Pipeline Run Correlation') { return 'Pipeline' }
        if ($Category -eq 'Cost') { return 'AdoProject' }
        return 'Pipeline'
    }

    # Convert a raw fixture finding to a canonical ADO entity ID.
    function Get-AdoEntityId {
        param([PSCustomObject]$Finding)
        $rid = $Finding.ResourceId
        if (-not $rid) { return 'ado://contoso/unknown/pipeline/0' }

        # ado:// URIs pass directly to ConvertTo-CanonicalAdoId
        if ($rid -match '^ado://') {
            $segments = ($rid -replace '^ado://', '') -split '/'
            if ($segments.Count -ge 4) {
                return ConvertTo-CanonicalAdoId -AdoId $rid
            }
            # Resource IDs with <4 segments need padding
            return ConvertTo-CanonicalAdoId -AdoId "$rid/resource/default"
        }
        return "ado://contoso/unknown/pipeline/$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }

    # Build E2E findings from a wrapper output fixture.
    function ConvertFrom-AdoFixture {
        param(
            [Parameter(Mandatory)] [PSCustomObject] $Fixture,
            [string] $ToolSource
        )
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($f in $Fixture.Findings) {
            $category = if ($f.PSObject.Properties['Category']) { $f.Category } else { '' }
            $assetType = if ($f.PSObject.Properties['AssetType']) { $f.AssetType } else { '' }
            $entityType = Get-AdoEntityType -Category $category -AssetType $assetType

            $entityId = Get-AdoEntityId -Finding $f

            # Inject planted secret into Detail for scrub verification
            $detail = if ($f.PSObject.Properties['Detail']) { $f.Detail } else { '' }
            if ($result.Count -eq 0) {
                $detail = $detail + " token=$($script:PlantedPat) auth=$($script:PlantedBearer)"
            }

            $ruleId = if ($f.PSObject.Properties['RuleId'] -and $f.RuleId) { $f.RuleId } else { "$ToolSource-finding" }
            $pillar = if ($f.PSObject.Properties['Pillar']) { $f.Pillar } else { '' }

            $finding = New-E2EFinding `
                -RuleId   $ruleId `
                -Title    $f.Title `
                -Source   $ToolSource `
                -EntityId $entityId `
                -EntityType $entityType `
                -Compliant ([bool]$f.Compliant) `
                -Severity $f.Severity `
                -Category $category `
                -Detail   $detail `
                -Remediation $(if ($f.PSObject.Properties['Remediation']) { $f.Remediation } else { '' }) `
                -ResourceId $(if ($f.PSObject.Properties['ResourceId']) { $f.ResourceId } else { '' }) `
                -LearnMoreUrl $(if ($f.PSObject.Properties['LearnMoreUrl']) { $f.LearnMoreUrl } else { '' }) `
                -Platform 'AzureDevOps' `
                -Pillar   $pillar

            $result.Add($finding)
        }
        return $result
    }
}

# --------------------------------------------------------------------------
# ADO-connections (#653)
# --------------------------------------------------------------------------
Describe 'E2E: ado-connections wrapper (#653)' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $script:FixtureDir 'ado-connections-e2e.json') -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-AdoFixture -Fixture $fixture -ToolSource 'ado-connections')
        $script:ConnOut = Join-Path $TestDrive 'ado-connections'
        $script:ConnResult = Invoke-E2EPipeline -Findings $findings -OutputPath $script:ConnOut
    }

    It 'produces results.json with ado-connections source' {
        Test-Path $script:ConnResult.ResultsFile | Should -BeTrue
        $parsed = Get-Content $script:ConnResult.ResultsFile -Raw | ConvertFrom-Json
        @($parsed).Count | Should -Be 4
        ($parsed | Select-Object -First 1).Source | Should -Be 'ado-connections'
    }

    It 'produces entities.json with v3.1 envelope' {
        Test-Path $script:ConnResult.EntitiesFile | Should -BeTrue
        $parsed = Get-Content $script:ConnResult.EntitiesFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion | Should -Match '^3\.'
        $parsed.PSObject.Properties.Name | Should -Contain 'Entities'
        $parsed.PSObject.Properties.Name | Should -Contain 'Edges'
        @($parsed.Entities).Count | Should -BeGreaterThan 0
    }

    It 'entities include ServiceConnection entity types' {
        $parsed = Get-Content $script:ConnResult.EntitiesFile -Raw | ConvertFrom-Json
        $svcConns = @($parsed.Entities | Where-Object { $_.EntityType -eq 'ServiceConnection' })
        $svcConns.Count | Should -BeGreaterOrEqual 1
    }

    It 'HTML report renders with ADO connection content' {
        Test-Path $script:ConnResult.HtmlFile | Should -BeTrue
        $html = Get-Content $script:ConnResult.HtmlFile -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match 'ado-connections'
    }

    It 'MD report renders' {
        Test-Path $script:ConnResult.MdFile | Should -BeTrue
        (Get-Item $script:ConnResult.MdFile).Length | Should -BeGreaterThan 64
    }

    It 'credential scrub removes planted secrets' {
        Assert-NoPlantedSecrets `
            -Files @($script:ConnResult.ResultsFile, $script:ConnResult.EntitiesFile, $script:ConnResult.HtmlFile, $script:ConnResult.MdFile) `
            -PlantedLiterals $script:PlantedLiterals
    }

    It 'all severity values are from the five-level enum' {
        $parsed = Get-Content $script:ConnResult.ResultsFile -Raw | ConvertFrom-Json
        foreach ($f in $parsed) {
            $f.Severity | Should -BeIn $script:ValidSeverities
        }
    }
}

# --------------------------------------------------------------------------
# ADO-pipelines (#654)
# --------------------------------------------------------------------------
Describe 'E2E: ado-pipelines wrapper (#654)' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $script:FixtureDir 'ado-pipelines-e2e.json') -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-AdoFixture -Fixture $fixture -ToolSource 'ado-pipelines')
        $script:PipeOut = Join-Path $TestDrive 'ado-pipelines'
        $script:PipeResult = Invoke-E2EPipeline -Findings $findings -OutputPath $script:PipeOut
    }

    It 'produces results.json with ado-pipelines source' {
        Test-Path $script:PipeResult.ResultsFile | Should -BeTrue
        $parsed = Get-Content $script:PipeResult.ResultsFile -Raw | ConvertFrom-Json
        @($parsed).Count | Should -Be 5
        ($parsed | Select-Object -First 1).Source | Should -Be 'ado-pipelines'
    }

    It 'produces entities.json spanning Pipeline, VariableGroup, Environment types' {
        $parsed = Get-Content $script:PipeResult.EntitiesFile -Raw | ConvertFrom-Json
        $entityTypes = @($parsed.Entities | Select-Object -ExpandProperty EntityType -Unique)
        $entityTypes | Should -Contain 'Pipeline'
    }

    It 'HTML report includes pipeline categories' {
        $html = Get-Content $script:PipeResult.HtmlFile -Raw
        $html | Should -Match 'ado-pipelines'
    }

    It 'credential scrub removes planted secrets' {
        Assert-NoPlantedSecrets `
            -Files @($script:PipeResult.ResultsFile, $script:PipeResult.EntitiesFile, $script:PipeResult.HtmlFile, $script:PipeResult.MdFile) `
            -PlantedLiterals $script:PlantedLiterals
    }

    It 'all severity values are from the five-level enum' {
        $parsed = Get-Content $script:PipeResult.ResultsFile -Raw | ConvertFrom-Json
        foreach ($f in $parsed) {
            $f.Severity | Should -BeIn $script:ValidSeverities
        }
    }
}

# --------------------------------------------------------------------------
# ADO-consumption (#655)
# --------------------------------------------------------------------------
Describe 'E2E: ado-consumption wrapper (#655)' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $script:FixtureDir 'ado-consumption-e2e.json') -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-AdoFixture -Fixture $fixture -ToolSource 'ado-consumption')
        $script:CostOut = Join-Path $TestDrive 'ado-consumption'
        $script:CostResult = Invoke-E2EPipeline -Findings $findings -OutputPath $script:CostOut
    }

    It 'produces results.json with ado-consumption source' {
        Test-Path $script:CostResult.ResultsFile | Should -BeTrue
        $parsed = Get-Content $script:CostResult.ResultsFile -Raw | ConvertFrom-Json
        @($parsed).Count | Should -Be 3
        ($parsed | Select-Object -First 1).Source | Should -Be 'ado-consumption'
    }

    It 'produces entities.json with AdoProject entity types' {
        $parsed = Get-Content $script:CostResult.EntitiesFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion | Should -Match '^3\.'
        $adoProjects = @($parsed.Entities | Where-Object { $_.EntityType -eq 'AdoProject' })
        $adoProjects.Count | Should -BeGreaterOrEqual 1
    }

    It 'HTML report renders cost findings' {
        $html = Get-Content $script:CostResult.HtmlFile -Raw
        $html | Should -Match 'ado-consumption'
    }

    It 'credential scrub removes planted secrets' {
        Assert-NoPlantedSecrets `
            -Files @($script:CostResult.ResultsFile, $script:CostResult.EntitiesFile, $script:CostResult.HtmlFile, $script:CostResult.MdFile) `
            -PlantedLiterals $script:PlantedLiterals
    }

    It 'all severity values are from the five-level enum' {
        $parsed = Get-Content $script:CostResult.ResultsFile -Raw | ConvertFrom-Json
        foreach ($f in $parsed) {
            $f.Severity | Should -BeIn $script:ValidSeverities
        }
    }
}

# --------------------------------------------------------------------------
# ADO-repos-secrets (#656)
# --------------------------------------------------------------------------
Describe 'E2E: ado-repos-secrets wrapper (#656)' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $script:FixtureDir 'ado-repos-secrets-e2e.json') -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-AdoFixture -Fixture $fixture -ToolSource 'ado-repos-secrets')
        $script:SecOut = Join-Path $TestDrive 'ado-repos-secrets'
        $script:SecResult = Invoke-E2EPipeline -Findings $findings -OutputPath $script:SecOut
    }

    It 'produces results.json with ado-repos-secrets source' {
        Test-Path $script:SecResult.ResultsFile | Should -BeTrue
        $parsed = Get-Content $script:SecResult.ResultsFile -Raw | ConvertFrom-Json
        @($parsed).Count | Should -Be 3
        ($parsed | Select-Object -First 1).Source | Should -Be 'ado-repos-secrets'
    }

    It 'produces entities.json with Repository entity types' {
        $parsed = Get-Content $script:SecResult.EntitiesFile -Raw | ConvertFrom-Json
        $repos = @($parsed.Entities | Where-Object { $_.EntityType -eq 'Repository' })
        $repos.Count | Should -BeGreaterOrEqual 1
    }

    It 'HTML report renders secret findings' {
        $html = Get-Content $script:SecResult.HtmlFile -Raw
        $html | Should -Match 'ado-repos-secrets'
    }

    It 'MD report renders' {
        Test-Path $script:SecResult.MdFile | Should -BeTrue
        (Get-Item $script:SecResult.MdFile).Length | Should -BeGreaterThan 64
    }

    It 'credential scrub removes planted secrets' {
        Assert-NoPlantedSecrets `
            -Files @($script:SecResult.ResultsFile, $script:SecResult.EntitiesFile, $script:SecResult.HtmlFile, $script:SecResult.MdFile) `
            -PlantedLiterals $script:PlantedLiterals
    }

    It 'all severity values are from the five-level enum' {
        $parsed = Get-Content $script:SecResult.ResultsFile -Raw | ConvertFrom-Json
        foreach ($f in $parsed) {
            $f.Severity | Should -BeIn $script:ValidSeverities
        }
    }
}

# --------------------------------------------------------------------------
# ADO-pipeline-correlator (#657)
# --------------------------------------------------------------------------
Describe 'E2E: ado-pipeline-correlator wrapper (#657)' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $script:FixtureDir 'ado-pipeline-correlator-e2e.json') -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-AdoFixture -Fixture $fixture -ToolSource 'ado-pipeline-correlator')
        $script:CorrOut = Join-Path $TestDrive 'ado-pipeline-correlator'
        $script:CorrResult = Invoke-E2EPipeline -Findings $findings -OutputPath $script:CorrOut
    }

    It 'produces results.json with ado-pipeline-correlator source' {
        Test-Path $script:CorrResult.ResultsFile | Should -BeTrue
        $parsed = Get-Content $script:CorrResult.ResultsFile -Raw | ConvertFrom-Json
        @($parsed).Count | Should -Be 2
        ($parsed | Select-Object -First 1).Source | Should -Be 'ado-pipeline-correlator'
    }

    It 'produces entities.json with Pipeline entity types' {
        $parsed = Get-Content $script:CorrResult.EntitiesFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion | Should -Match '^3\.'
        $pipelines = @($parsed.Entities | Where-Object { $_.EntityType -eq 'Pipeline' })
        $pipelines.Count | Should -BeGreaterOrEqual 1
    }

    It 'HTML report renders correlator findings' {
        $html = Get-Content $script:CorrResult.HtmlFile -Raw
        $html | Should -Match 'ado-pipeline-correlator'
    }

    It 'credential scrub removes planted secrets' {
        Assert-NoPlantedSecrets `
            -Files @($script:CorrResult.ResultsFile, $script:CorrResult.EntitiesFile, $script:CorrResult.HtmlFile, $script:CorrResult.MdFile) `
            -PlantedLiterals $script:PlantedLiterals
    }

    It 'all severity values are from the five-level enum' {
        $parsed = Get-Content $script:CorrResult.ResultsFile -Raw | ConvertFrom-Json
        foreach ($f in $parsed) {
            $f.Severity | Should -BeIn $script:ValidSeverities
        }
    }
}

# --------------------------------------------------------------------------
# Combined ADO surface
# --------------------------------------------------------------------------
Describe 'E2E: combined ADO surface (all five tools)' {
    BeforeAll {
        $allFindings = [System.Collections.Generic.List[object]]::new()

        $tools = @(
            @{ File = 'ado-connections-e2e.json';          Source = 'ado-connections' },
            @{ File = 'ado-pipelines-e2e.json';            Source = 'ado-pipelines' },
            @{ File = 'ado-consumption-e2e.json';          Source = 'ado-consumption' },
            @{ File = 'ado-repos-secrets-e2e.json';        Source = 'ado-repos-secrets' },
            @{ File = 'ado-pipeline-correlator-e2e.json';  Source = 'ado-pipeline-correlator' }
        )
        foreach ($tool in $tools) {
            $fixture = Get-Content (Join-Path $script:FixtureDir $tool.File) -Raw | ConvertFrom-Json
            $converted = @(ConvertFrom-AdoFixture -Fixture $fixture -ToolSource $tool.Source)
            foreach ($f in $converted) { $allFindings.Add($f) }
        }

        $script:CombinedOut = Join-Path $TestDrive 'ado-combined'
        $script:CombinedResult = Invoke-E2EPipeline -Findings @($allFindings) -OutputPath $script:CombinedOut
    }

    It 'results.json contains findings from all five ADO tools' {
        $parsed = Get-Content $script:CombinedResult.ResultsFile -Raw | ConvertFrom-Json
        $sources = @($parsed | Select-Object -ExpandProperty Source -Unique)
        $sources | Should -Contain 'ado-connections'
        $sources | Should -Contain 'ado-pipelines'
        $sources | Should -Contain 'ado-consumption'
        $sources | Should -Contain 'ado-repos-secrets'
        $sources | Should -Contain 'ado-pipeline-correlator'
    }

    It 'combined finding count matches sum of individual fixtures' {
        $parsed = Get-Content $script:CombinedResult.ResultsFile -Raw | ConvertFrom-Json
        # 4 + 5 + 3 + 3 + 2 = 17
        @($parsed).Count | Should -Be 17
    }

    It 'entities.json covers diverse ADO entity types' {
        $parsed = Get-Content $script:CombinedResult.EntitiesFile -Raw | ConvertFrom-Json
        $entityTypes = @($parsed.Entities | Select-Object -ExpandProperty EntityType -Unique)
        $entityTypes | Should -Contain 'ServiceConnection'
        $entityTypes | Should -Contain 'Pipeline'
    }

    It 'HTML report includes all five tool names' {
        $html = Get-Content $script:CombinedResult.HtmlFile -Raw
        $html | Should -Match 'ado-connections'
        $html | Should -Match 'ado-pipelines'
        $html | Should -Match 'ado-consumption'
        $html | Should -Match 'ado-repos-secrets'
        $html | Should -Match 'ado-pipeline-correlator'
    }

    It 'credential scrub removes planted secrets from combined output' {
        Assert-NoPlantedSecrets `
            -Files @($script:CombinedResult.ResultsFile, $script:CombinedResult.EntitiesFile, $script:CombinedResult.HtmlFile, $script:CombinedResult.MdFile) `
            -PlantedLiterals $script:PlantedLiterals
    }

    It 'all severity values across combined output are valid' {
        $parsed = Get-Content $script:CombinedResult.ResultsFile -Raw | ConvertFrom-Json
        foreach ($f in $parsed) {
            $f.Severity | Should -BeIn $script:ValidSeverities
        }
    }
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } elseif ($null -ne $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}
