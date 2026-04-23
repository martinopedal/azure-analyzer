#Requires -Version 7.4
<#
.SYNOPSIS
    Integration tests for -FixtureMode flag on Invoke-AzureAnalyzer.ps1.
.DESCRIPTION
    Verifies that the orchestrator produces real output artifacts when run
    against the test fixtures in tests/fixtures/ without any Azure credentials.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Orchestrator = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
    $script:FixtureDir   = Join-Path $script:RepoRoot 'tests' 'fixtures'
}

Describe 'FixtureMode integration' {

    Context 'Default fixture path' {
        BeforeAll {
            $script:OutDir = Join-Path $TestDrive 'fixture-default'
            $result = pwsh -NoProfile -Command "& '$script:Orchestrator' -FixtureMode -OutputPath '$script:OutDir' -NoBanner 2>&1"
            $script:ExitCode = $LASTEXITCODE
            # Strip ANSI escape codes to avoid Pester NUnit XML serialization errors
            $script:Output = ($result -join "`n") -replace '\x1B\[[0-9;]*m', ''
        }

        It 'exits with code 0' {
            $script:ExitCode | Should -Be 0
        }

        It 'creates results.json' {
            Join-Path $script:OutDir 'results.json' | Should -Exist
        }

        It 'creates entities.json with v3.1 schema' {
            $entitiesPath = Join-Path $script:OutDir 'entities.json'
            $entitiesPath | Should -Exist
            $payload = Get-Content $entitiesPath -Raw | ConvertFrom-Json
            $payload.SchemaVersion | Should -Be '3.1'
            $payload.Entities | Should -Not -BeNullOrEmpty
        }

        It 'creates HTML report' {
            Join-Path $script:OutDir 'report.html' | Should -Exist
        }

        It 'creates Markdown report' {
            Join-Path $script:OutDir 'report.md' | Should -Exist
        }

        It 'creates tool-status.json' {
            $statusPath = Join-Path $script:OutDir 'tool-status.json'
            $statusPath | Should -Exist
            $status = Get-Content $statusPath -Raw | ConvertFrom-Json
            $status | Should -Not -BeNullOrEmpty
        }

        It 'produces findings from at least 3 tools' {
            $statusPath = Join-Path $script:OutDir 'tool-status.json'
            $status = Get-Content $statusPath -Raw | ConvertFrom-Json
            $toolsWithFindings = @($status | Where-Object { $_.Findings -gt 0 })
            $toolsWithFindings.Count | Should -BeGreaterOrEqual 3
        }

        It 'produces non-zero total findings in results.json' {
            $resultsPath = Join-Path $script:OutDir 'results.json'
            $results = Get-Content $resultsPath -Raw | ConvertFrom-Json
            @($results).Count | Should -BeGreaterThan 0
        }

        It 'logs SKIP for tools without fixtures' {
            $script:Output | Should -Match 'SKIP'
        }
    }

    Context 'Custom fixture path' {
        BeforeAll {
            $script:CustomFixtureDir = Join-Path $TestDrive 'custom-fixtures'
            New-Item -ItemType Directory -Path $script:CustomFixtureDir -Force | Out-Null
            # Copy a single fixture to the custom dir
            Copy-Item (Join-Path $script:FixtureDir 'trivy-output.json') $script:CustomFixtureDir

            $script:OutDir2 = Join-Path $TestDrive 'fixture-custom'
            $result = pwsh -NoProfile -Command "& '$script:Orchestrator' -FixtureMode -FixturePath '$script:CustomFixtureDir' -OutputPath '$script:OutDir2' -NoBanner 2>&1"
            $script:ExitCode2 = $LASTEXITCODE
        }

        It 'exits with code 0' {
            $script:ExitCode2 | Should -Be 0
        }

        It 'produces results.json' {
            Join-Path $script:OutDir2 'results.json' | Should -Exist
        }
    }

    Context 'Invalid fixture path' {
        It 'exits non-zero for missing fixture directory' {
            $outDir = Join-Path $TestDrive 'fixture-missing'
            $null = pwsh -NoProfile -Command "& '$script:Orchestrator' -FixtureMode -FixturePath 'C:\nonexistent\path' -OutputPath '$outDir' -NoBanner 2>&1"
            $LASTEXITCODE | Should -Not -Be 0
        }
    }

    Context 'IncludeTools filter' {
        BeforeAll {
            $script:OutDir3 = Join-Path $TestDrive 'fixture-include'
            $result = pwsh -NoProfile -Command "& '$script:Orchestrator' -FixtureMode -OutputPath '$script:OutDir3' -IncludeTools trivy,gitleaks -NoBanner 2>&1"
            $script:ExitCode3 = $LASTEXITCODE
        }

        It 'exits with code 0' {
            $script:ExitCode3 | Should -Be 0
        }

        It 'only includes specified tools in tool-status' {
            $statusPath = Join-Path $script:OutDir3 'tool-status.json'
            $status = Get-Content $statusPath -Raw | ConvertFrom-Json
            $toolNames = @($status | ForEach-Object { $_.Tool })
            $toolNames | Should -Contain 'trivy'
            $toolNames | Should -Contain 'gitleaks'
            # Should not contain unrelated tools
            $toolNames | Should -Not -Contain 'azqr'
        }
    }
}
