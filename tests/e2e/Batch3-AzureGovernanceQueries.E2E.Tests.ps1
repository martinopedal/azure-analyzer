#Requires -Version 7.4
<#
.SYNOPSIS
    E2E wrapper coverage batch 3 for #745: AKS optimization plus PSRule /
    Powerpipe / ALZ-queries governance scanners.
.DESCRIPTION
    Same orchestrator-pipeline pattern as batch 1; per-tool fixtures feed
    Invoke-E2EPipeline and assert the v1+v3.1 envelope shape, scrub, and
    report render.
.NOTES
    Tracker: docs/audits/e2e-wrapper-coverage-parity.json (E2E-012, E2E-013,
    E2E-014, E2E-015, E2E-017).
#>
Set-StrictMode -Version Latest

# Pester requires RepoRoot in both BeforeDiscovery (used to enumerate test
# data at discovery time) and BeforeAll (used at runtime by the test body).
# The two scopes do not share variables, so the value is computed in each.
BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Tools = @(
        @{ Name = 'aks-rightsizing';     Fixture = 'aks-rightsizing-e2e.json';     ExpectedFindings = 3; Platform = 'Azure' }
        @{ Name = 'aks-karpenter-cost';  Fixture = 'aks-karpenter-cost-e2e.json';  ExpectedFindings = 3; Platform = 'Azure' }
        @{ Name = 'psrule';              Fixture = 'psrule-e2e.json';              ExpectedFindings = 3; Platform = 'Azure' }
        @{ Name = 'powerpipe';           Fixture = 'powerpipe-e2e.json';           ExpectedFindings = 3; Platform = 'Azure' }
        @{ Name = 'alz-queries';         Fixture = 'alz-queries-e2e.json';         ExpectedFindings = 3; Platform = 'Azure' }
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

    $script:PlantedPat    = 'gh' + 'p_' + 'FAKEFORTESTONLYAZURE745E2EBATCH3xxxx'
    $script:PlantedBearer = 'Be' + 'arer ' + 'eyJhbGciOi' + 'JIUzI1NiJ9' + '.FAKE_FOR_TEST_ONLY_AZURE_E2E_PAYLOAD.signature'
    $script:PlantedLiterals = @($script:PlantedPat, $script:PlantedBearer)

    function ConvertFrom-AzureFixture {
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

            $resourceId = if ($f.PSObject.Properties['ResourceId']) { $f.ResourceId } else { '' }
            $entityType = 'AzureResource'
            $rawIdForCanon = $resourceId
            if ($resourceId -match '^/subscriptions/([0-9a-fA-F-]{36})$') {
                $entityType = 'Subscription'
                $rawIdForCanon = $matches[1]
            }
            $canon = ConvertTo-CanonicalEntityId -RawId $rawIdForCanon -EntityType $entityType
            $entityId = $canon.CanonicalId

            $rows.Add( (New-E2EFinding `
                -RuleId      ($f.RuleId) `
                -Title       ($f.Title) `
                -Source      $ToolSource `
                -EntityId    $entityId `
                -EntityType  $entityType `
                -Compliant   ([bool]$f.Compliant) `
                -Severity    ($f.Severity) `
                -Category    ($f.Category) `
                -Detail      $detail `
                -Remediation ($f.Remediation) `
                -ResourceId  $resourceId `
                -Platform    'Azure' `
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

Describe 'E2E batch 3 (#745): <_.Name>' -ForEach $script:Tools {

    BeforeAll {
        $tool = $_
        $fixturePath = Join-Path $script:FixtureDir $tool.Fixture
        Test-Path $fixturePath | Should -BeTrue
        $fixture  = Get-Content $fixturePath -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-AzureFixture -Fixture $fixture -ToolSource $tool.Name)

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

    It 'produces entities.json with v3.1 envelope and entities' {
        Test-Path $script:Result.EntitiesFile | Should -BeTrue
        $parsed = Get-Content $script:Result.EntitiesFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion | Should -Match '^3\.'
        $parsed.PSObject.Properties.Name | Should -Contain 'Entities'
        $parsed.PSObject.Properties.Name | Should -Contain 'Edges'
        @($parsed.Entities).Count | Should -BeGreaterThan 0
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
