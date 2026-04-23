#Requires -Version 7.4
<#
.SYNOPSIS
    Integration test for -FixtureMode flag.
.DESCRIPTION
    Validates that azure-analyzer can run end-to-end against test fixtures
    without Azure credentials, producing valid results.json, entities.json,
    and HTML/MD reports.
#>

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:OrchestratorPath = Join-Path $RepoRoot 'Invoke-AzureAnalyzer.ps1'
    $script:TestOutputPath = Join-Path $RepoRoot 'output-fixture-test'
}

Describe 'FixtureMode E2E' -Tag 'Integration', 'FixtureMode' {
    BeforeEach {
        if (Test-Path $script:TestOutputPath) {
            Remove-Item $script:TestOutputPath -Recurse -Force
        }
    }
    
    AfterEach {
        if (Test-Path $script:TestOutputPath) {
            Remove-Item $script:TestOutputPath -Recurse -Force
        }
    }
    
    It 'Runs successfully with -FixtureMode flag' {
        $result = & pwsh -NoProfile -Command "& '$script:OrchestratorPath' -FixtureMode -OutputPath '$script:TestOutputPath' -ErrorAction Stop" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "orchestrator should exit cleanly in FixtureMode"
    }
    
    It 'Creates results.json in fixture mode' {
        & pwsh -NoProfile -Command "& '$script:OrchestratorPath' -FixtureMode -OutputPath '$script:TestOutputPath' -ErrorAction Stop" | Out-Null
        $resultsPath = Join-Path $script:TestOutputPath 'results.json'
        $resultsPath | Should -Exist
        
        $results = Get-Content $resultsPath -Raw | ConvertFrom-Json
        $results | Should -Not -BeNullOrEmpty
        $results | Should -BeOfType [System.Object]
    }
    
    It 'Creates entities.json in fixture mode' {
        & pwsh -NoProfile -Command "& '$script:OrchestratorPath' -FixtureMode -OutputPath '$script:TestOutputPath' -ErrorAction Stop" | Out-Null
        $entitiesPath = Join-Path $script:TestOutputPath 'entities.json'
        $entitiesPath | Should -Exist
        
        $entities = Get-Content $entitiesPath -Raw | ConvertFrom-Json
        $entities | Should -Not -BeNullOrEmpty
    }
    
    It 'Creates report.html in fixture mode' {
        & pwsh -NoProfile -Command "& '$script:OrchestratorPath' -FixtureMode -OutputPath '$script:TestOutputPath' -ErrorAction Stop" | Out-Null
        $htmlPath = Join-Path $script:TestOutputPath 'report.html'
        $htmlPath | Should -Exist
        
        $htmlContent = Get-Content $htmlPath -Raw
        $htmlContent | Should -Not -BeNullOrEmpty
        $htmlContent | Should -Match '<!DOCTYPE html>'
    }
    
    It 'Produces findings from at least 3 tools' {
        & pwsh -NoProfile -Command "& '$script:OrchestratorPath' -FixtureMode -OutputPath '$script:TestOutputPath' -ErrorAction Stop" | Out-Null
        $resultsPath = Join-Path $script:TestOutputPath 'results.json'
        $results = Get-Content $resultsPath -Raw | ConvertFrom-Json
        
        if ($results.PSObject.Properties['findings']) {
            $sources = $results.findings | Select-Object -ExpandProperty Source -Unique
        } elseif ($results -is [array]) {
            $sources = $results | Select-Object -ExpandProperty Source -Unique
        } else {
            throw "Unexpected results.json structure"
        }
        
        $sources.Count | Should -BeGreaterOrEqual 3 -Because "at least 3 tools should produce findings from fixtures"
    }
    
    It 'Runs without Azure credentials' {
        # Temporarily clear any Az context
        $originalContext = $env:AZURE_CONFIG_DIR
        $env:AZURE_CONFIG_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "az-test-$(New-Guid)"
        
        try {
            $result = & pwsh -NoProfile -Command "& '$script:OrchestratorPath' -FixtureMode -OutputPath '$script:TestOutputPath' -ErrorAction Stop" 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "FixtureMode should not require Azure auth"
        } finally {
            if ($originalContext) {
                $env:AZURE_CONFIG_DIR = $originalContext
            } else {
                Remove-Item env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
            }
            if (Test-Path $env:AZURE_CONFIG_DIR) {
                Remove-Item $env:AZURE_CONFIG_DIR -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    It 'Skips tools without fixtures gracefully' {
        $output = & pwsh -NoProfile -Command "& '$script:OrchestratorPath' -FixtureMode -OutputPath '$script:TestOutputPath'" 2>&1 | Out-String
        # Should contain SKIP messages for tools without fixtures
        $output | Should -Match 'SKIP:.*no fixture'
    }
}
