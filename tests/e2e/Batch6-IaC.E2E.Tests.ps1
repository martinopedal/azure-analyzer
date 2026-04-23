#Requires -Version 7.4
<#
.SYNOPSIS
    E2E wrapper coverage batch 6 for #663 / #664 / #665: IaC scanners.

.DESCRIPTION
    Same orchestrator-pipeline pattern as batch 4 (repo-scoped scanners) but
    targets the three IaC tools that scan a checked-out infrastructure-as-code
    repository: bicep-iac, infracost, terraform-iac. Entity type is Repository
    (canonicalised via ConvertTo-CanonicalEntityId).

    Schema invariants asserted on every tool:
      * results.json is valid JSON (v1-compat FindingRow array)
      * entities.json uses v3.1 shape { SchemaVersion, Entities, Edges }
      * HTML and Markdown reports render
      * Credential scrubbing removes planted secrets from every artifact
      * Source tag matches the tool name
      * Severity values are within the five-level enum
      * EntityType is a valid Schema.ps1 enum value
      * At least one Repository entity is emitted

.NOTES
    Tracker: docs/audits/e2e-wrapper-coverage-parity.json (E2E-032, E2E-033,
    E2E-034). Tools were graduated to `covered` in batch 5/5 (#766); this batch
    backs that status with the actual orchestrator-pipeline coverage.
#>
Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Tools = @(
        @{ Name = 'bicep-iac';     Fixture = 'bicep-iac-e2e.json';     ExpectedFindings = 3 }
        @{ Name = 'infracost';     Fixture = 'infracost-e2e.json';     ExpectedFindings = 3 }
        @{ Name = 'terraform-iac'; Fixture = 'terraform-iac-e2e.json'; ExpectedFindings = 3 }
    )
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:_origSuppressMissingTools = $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS
    $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

    Get-Module AzureAnalyzer -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'AzureAnalyzer.psd1') -Force

    $sharedDir = Join-Path $script:RepoRoot 'modules' 'shared'
    foreach ($sharedScript in (Get-ChildItem -Path $sharedDir -Filter '*.ps1' -File)) {
        . $sharedScript.FullName
    }

    . (Join-Path $PSScriptRoot '_E2EHelpers.ps1')

    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:ValidSeverities = @('Critical', 'High', 'Medium', 'Low', 'Info')
    $script:ValidEntityTypes = @(
        'AzureResource', 'ServicePrincipal', 'ManagedIdentity', 'Application',
        'Repository', 'IaCFile', 'BuildDefinition', 'ReleaseDefinition',
        'Pipeline', 'VariableGroup', 'Environment', 'ServiceConnection',
        'User', 'Subscription', 'ManagementGroup', 'Workflow', 'Tenant',
        'AdoProject', 'KarpenterProvisioner'
    )

    $script:PlantedPat    = 'ghp_FAKEAZURE663665E2EBATCH6234567890abEF'
    $script:PlantedBearer = 'Bearer eyJhbGciOiJIUzI1NiJ9.FAKE_AZURE_E2E_PAYLOAD.signature'
    $script:PlantedLiterals = @($script:PlantedPat, $script:PlantedBearer)

    function ConvertFrom-IaCFixture {
        param(
            [Parameter(Mandatory)] [PSCustomObject] $Fixture,
            [Parameter(Mandatory)] [string] $ToolSource
        )
        $rows = [System.Collections.Generic.List[object]]::new()
        $i = 0
        foreach ($f in $Fixture.Findings) {
            $detail = if ($f.PSObject.Properties['Detail']) { $f.Detail } else { '' }
            if ($i -eq 0) {
                $detail = "$detail token=$($script:PlantedPat) auth=$($script:PlantedBearer)"
            }
            $i++

            $repoId = if ($f.PSObject.Properties['RepoId']) { $f.RepoId } else { 'https://github.com/contoso/azure-iac' }
            $canon = ConvertTo-CanonicalEntityId -RawId $repoId -EntityType 'Repository'
            $platform = if ($canon.CanonicalId -match '^ado://') { 'ADO' } else { 'GitHub' }

            $rows.Add( (New-E2EFinding `
                -RuleId      ($f.RuleId) `
                -Title       ($f.Title) `
                -Source      $ToolSource `
                -EntityId    $canon.CanonicalId `
                -EntityType  'Repository' `
                -Compliant   ([bool]$f.Compliant) `
                -Severity    ($f.Severity) `
                -Category    ($f.Category) `
                -Detail      $detail `
                -Remediation ($f.Remediation) `
                -ResourceId  $repoId `
                -Platform    $platform `
                -Pillar      ($f.Pillar) `
            ) )
        }
        return $rows
    }
}

AfterAll {
    if ($null -ne $script:_origSuppressMissingTools) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $script:_origSuppressMissingTools
    } else {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    }
}

Describe 'E2E batch 6 (#663/#664/#665): <_.Name>' -ForEach $script:Tools {

    BeforeAll {
        $tool = $_
        $fixturePath = Join-Path $script:FixtureDir $tool.Fixture
        Test-Path $fixturePath | Should -BeTrue
        $fixture  = Get-Content $fixturePath -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-IaCFixture -Fixture $fixture -ToolSource $tool.Name)

        $script:ToolName        = $tool.Name
        $script:ExpectedFindings = $tool.ExpectedFindings
        $script:OutDir = Join-Path $TestDrive ($tool.Name -replace '[^a-zA-Z0-9]', '-')
        $script:Result = Invoke-E2EPipeline -Findings $findings -OutputPath $script:OutDir
    }

    It 'produces results.json with expected source and at least one finding' {
        Test-Path $script:Result.ResultsFile | Should -BeTrue
        $parsed = @(Get-Content $script:Result.ResultsFile -Raw | ConvertFrom-Json)
        $parsed.Count | Should -BeGreaterThan 0
        ($parsed | Select-Object -First 1).Source | Should -Be $script:ToolName
    }

    It 'produces entities.json with v3.1 envelope and Repository entities' {
        Test-Path $script:Result.EntitiesFile | Should -BeTrue
        $parsed = Get-Content $script:Result.EntitiesFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion | Should -Match '^3\.'
        $parsed.PSObject.Properties.Name | Should -Contain 'Entities'
        $parsed.PSObject.Properties.Name | Should -Contain 'Edges'
        @($parsed.Entities | Where-Object { $_.EntityType -eq 'Repository' }).Count | Should -BeGreaterThan 0
    }

    It 'all entities use a valid EntityType enum value' {
        $parsed = Get-Content $script:Result.EntitiesFile -Raw | ConvertFrom-Json
        foreach ($e in $parsed.Entities) {
            $e.EntityType | Should -BeIn $script:ValidEntityTypes
        }
    }

    It 'all severity values are from the five-level enum' {
        $parsed = Get-Content $script:Result.ResultsFile -Raw | ConvertFrom-Json
        foreach ($f in $parsed) { $f.Severity | Should -BeIn $script:ValidSeverities }
    }

    It 'HTML report renders with the tool source name' {
        Test-Path $script:Result.HtmlFile | Should -BeTrue
        $html = Get-Content $script:Result.HtmlFile -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match ([regex]::Escape($script:ToolName))
    }

    It 'Markdown report renders with non-empty content' {
        Test-Path $script:Result.MdFile | Should -BeTrue
        (Get-Item $script:Result.MdFile).Length | Should -BeGreaterThan 64
    }

    It 'credential scrub removes planted secrets from every artifact' {
        Assert-NoPlantedSecrets `
            -Files @($script:Result.ResultsFile, $script:Result.EntitiesFile, $script:Result.HtmlFile, $script:Result.MdFile) `
            -PlantedLiterals $script:PlantedLiterals
    }
}
