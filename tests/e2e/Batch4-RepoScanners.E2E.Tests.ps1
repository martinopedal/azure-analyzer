#Requires -Version 7.4
<#
.SYNOPSIS
    E2E wrapper coverage batch 4 for #745: CLI repo-scoped scanners.
.DESCRIPTION
    Same orchestrator-pipeline pattern as batch 1 but targets the
    Repository entity type via ConvertTo-CanonicalRepoId. Each fixture
    represents a wrapper run against a remote GitHub repo URL.

    Tools covered: scorecard, gitleaks, trivy, zizmor, kubescape, kube-bench,
    falco.
.NOTES
    Tracker: docs/audits/e2e-wrapper-coverage-parity.json (E2E-002, E2E-003,
    E2E-006, E2E-020, E2E-029, E2E-030, E2E-031).
#>
Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Tools = @(
        @{ Name = 'scorecard';   Fixture = 'scorecard-e2e.json';   ExpectedFindings = 3 }
        @{ Name = 'gitleaks';    Fixture = 'gitleaks-e2e.json';    ExpectedFindings = 3 }
        @{ Name = 'trivy';       Fixture = 'trivy-e2e.json';       ExpectedFindings = 3 }
        @{ Name = 'zizmor';      Fixture = 'zizmor-e2e.json';      ExpectedFindings = 3 }
        @{ Name = 'kubescape';   Fixture = 'kubescape-e2e.json';   ExpectedFindings = 3 }
        @{ Name = 'kube-bench';  Fixture = 'kube-bench-e2e.json';  ExpectedFindings = 3 }
        @{ Name = 'falco';       Fixture = 'falco-e2e.json';       ExpectedFindings = 3 }
    )
}

BeforeAll {
    # NOTE: $script:RepoRoot is recomputed here (also set in BeforeDiscovery above)
    # because Pester evaluates BeforeDiscovery and BeforeAll in separate scopes;
    # the BeforeDiscovery binding is not visible inside BeforeAll/It blocks at run time.
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

    # Obviously-fake sentinel literals (avoid real GitHub PAT / JWT shapes) so that
    # GitHub secret scanning, gitleaks, and the in-repo no-secrets ratchet do not flag
    # this test fixture as a leaked credential. Both literals still match the
    # corresponding Sanitize.ps1 patterns (ghp_[A-Za-z0-9]{36} for the PAT, and
    # \bBearer\s+[A-Za-z0-9\-._~+/]+ for the bearer token), so Remove-Credentials
    # is exercised and the planted-secret assertion below remains meaningful.
    # Use the FAKEFORTESTONLY marker GitHub Secret Scanning treats as a non-secret.
    $script:PlantedPat    = 'ghp_FAKEFORTESTONLY1234567890abcdEFghijK'
    $script:PlantedBearer = 'Bearer FAKE_FOR_TEST_ONLY_AZURE_ANALYZER_E2E_BATCH4_BEARER'
    $script:PlantedLiterals = @($script:PlantedPat, $script:PlantedBearer)

    function ConvertFrom-RepoFixture {
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

            $repoId = if ($f.PSObject.Properties['RepoId']) { $f.RepoId } else { 'https://github.com/contoso/example' }
            # Use ConvertTo-CanonicalRepoId directly (per CHANGELOG entry for #765)
            # rather than the generic ConvertTo-CanonicalEntityId dispatcher, to keep
            # the contract under test explicit and aligned with the documented API.
            $canonicalId = ConvertTo-CanonicalRepoId -RepoId $repoId
            $platform = if ($canonicalId -match '^ado://') { 'ADO' } else { 'GitHub' }

            $rows.Add( (New-E2EFinding `
                -RuleId      ($f.RuleId) `
                -Title       ($f.Title) `
                -Source      $ToolSource `
                -EntityId    $canonicalId `
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

Describe 'E2E batch 4 (#745): <_.Name>' -ForEach $script:Tools {

    BeforeAll {
        $tool = $_
        $fixturePath = Join-Path $script:FixtureDir $tool.Fixture
        Test-Path $fixturePath | Should -BeTrue
        $fixture  = Get-Content $fixturePath -Raw | ConvertFrom-Json
        $findings = @(ConvertFrom-RepoFixture -Fixture $fixture -ToolSource $tool.Name)

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

    It 'produces entities.json with v3.1 envelope and Repository entities' {
        Test-Path $script:Result.EntitiesFile | Should -BeTrue
        $parsed = Get-Content $script:Result.EntitiesFile -Raw | ConvertFrom-Json
        $parsed.SchemaVersion | Should -Match '^3\.'
        @($parsed.Entities | Where-Object { $_.EntityType -eq 'Repository' }).Count | Should -BeGreaterThan 0
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
