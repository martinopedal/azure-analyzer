#Requires -Version 7.4
<#
.SYNOPSIS
    E2E wrapper coverage batch 5 for #745: identity and tenant-scope governance.
.DESCRIPTION
    Final batch. Mixed entity types per fixture: User / ServicePrincipal /
    Tenant / Workflow / AzureResource / Subscription. Each finding's
    EntityType is read from the fixture and routed through
    ConvertTo-CanonicalEntityId.

    Tools covered: identity-correlator, identity-graph-expansion, maester,
    gh-actions-billing, azgovviz, wara.
.NOTES
    Tracker: docs/audits/e2e-wrapper-coverage-parity.json (E2E entries for
    these six tools plus stale graduations for ado-* and bicep/infracost/terraform
    which already have E2E elsewhere).
#>
Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Tools = @(
        @{ Name = 'identity-correlator';        Fixture = 'identity-correlator-e2e.json' }
        @{ Name = 'identity-graph-expansion';   Fixture = 'identity-graph-expansion-e2e.json' }
        @{ Name = 'maester';                    Fixture = 'maester-e2e.json' }
        @{ Name = 'gh-actions-billing';         Fixture = 'gh-actions-billing-e2e.json' }
        @{ Name = 'azgovviz';                   Fixture = 'azgovviz-e2e.json' }
        @{ Name = 'wara';                       Fixture = 'wara-e2e.json' }
    )
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
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

    $script:PlantedPat    = 'ghp_FAKEAZURE745E2EBATCH5534567890abcdEF'
    $script:PlantedBearer = 'Bearer eyJhbGciOiJIUzI1NiJ9.FAKE_AZURE_E2E_PAYLOAD.signature'
    $script:PlantedLiterals = @($script:PlantedPat, $script:PlantedBearer)

    function ConvertFrom-MixedFixture {
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

            $entityType = if ($f.PSObject.Properties['EntityType']) { $f.EntityType } else { 'AzureResource' }
            $rawId      = if ($f.PSObject.Properties['EntityId']) { $f.EntityId } else { $f.ResourceId }

            $rawIdForCanon = $rawId
            if ($entityType -eq 'Subscription' -and $rawId -match '^/subscriptions/([0-9a-fA-F-]{36})$') {
                $rawIdForCanon = $matches[1]
            }

            $canon = ConvertTo-CanonicalEntityId -RawId $rawIdForCanon -EntityType $entityType
            $platform = $canon.Platform
            if ($platform -eq 'Unknown' -and $entityType -eq 'Workflow') { $platform = 'GitHub' }
            $resourceId = if ($f.PSObject.Properties['ResourceId']) { $f.ResourceId } else { $rawId }

            $rows.Add( (New-E2EFinding `
                -RuleId      ($f.RuleId) `
                -Title       ($f.Title) `
                -Source      $ToolSource `
                -EntityId    $canon.CanonicalId `
                -EntityType  $entityType `
                -Compliant   ([bool]$f.Compliant) `
                -Severity    ($f.Severity) `
                -Category    ($f.Category) `
                -Detail      $detail `
                -Remediation ($f.Remediation) `
                -ResourceId  $resourceId `
                -Platform    $platform `
                -Pillar      ($f.Pillar) `
            ) )
        }
        return $rows
    }
}

Describe 'E2E batch 5 (#745): <_.Name>' -ForEach $script:Tools {

    BeforeAll {
        $tool = $_
        $fixturePath = Join-Path $script:FixtureDir $tool.Fixture
        Test-Path $fixturePath | Should -BeTrue
        $fixture  = Get-Content $fixturePath -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-MixedFixture -Fixture $fixture -ToolSource $tool.Name)

        $script:ToolName = $tool.Name
        $script:OutDir = Join-Path $TestDrive ($tool.Name -replace '[^a-zA-Z0-9]', '-')
        $script:Result = Invoke-E2EPipeline -Findings $findings -OutputPath $script:OutDir
    }

    It 'produces results.json with expected source and at least one finding' {
        Test-Path $script:Result.ResultsFile | Should -BeTrue
        $parsed = @(Get-Content $script:Result.ResultsFile -Raw | ConvertFrom-Json)
        $parsed.Count | Should -BeGreaterThan 0
        ($parsed | Select-Object -First 1).Source | Should -Be $script:ToolName
    }

    It 'produces entities.json with v3.1 envelope and entities' {
        Test-Path $script:Result.EntitiesFile | Should -BeTrue
        $parsed = Get-Content $script:Result.EntitiesFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion | Should -Match '^3\.'
        @($parsed.Entities).Count | Should -BeGreaterThan 0
    }

    It 'all entities use a valid EntityType enum value' {
        $parsed = Get-Content $script:Result.EntitiesFile -Raw | ConvertFrom-Json
        foreach ($e in $parsed.Entities) { $e.EntityType | Should -BeIn $script:ValidEntityTypes }
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

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } elseif ($null -ne $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}
