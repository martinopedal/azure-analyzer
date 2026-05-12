#Requires -Version 7.4

Describe 'AuditorReportBuilder' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $modulePath = Join-Path $repoRoot 'modules' 'shared' 'AuditorReportBuilder.ps1'
        . $modulePath
        
        $fixtureDir = Join-Path $PSScriptRoot '..' 'fixtures' 'auditor-small'
        $resultsPath = Join-Path $fixtureDir 'results.json'
        $entitiesPath = Join-Path $fixtureDir 'entities.json'
        $manifestPath = Join-Path $fixtureDir 'report-manifest.json'
    }
    
    Context 'Resolve-AuditorContext' {
        It 'reads tier from manifest when both manifest and -Tier param present' {
            $context = Resolve-AuditorContext -InputPath $resultsPath -EntitiesPath $entitiesPath -ManifestPath $manifestPath -Tier 'PureJson'
            
            $context.Tier | Should -Be 'EmbeddedSqlite'
        }
        
        It 'loads all inputs when paths valid' {
            $context = Resolve-AuditorContext -InputPath $resultsPath -EntitiesPath $entitiesPath -ManifestPath $manifestPath
            
            $context.Findings.Count | Should -Be 10
            $context.Entities | Should -Not -BeNullOrEmpty
            $context.Entities.PSObject.Properties.Name | Should -Contain 'tenant:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $context.Manifest.profile.auditor | Should -Not -BeNullOrEmpty -Because 'profile.auditor block should exist'
        }
    }
    
    Context 'Get-AuditorExecutiveSummary' {
        BeforeAll {
            $findings = Get-Content -Path $resultsPath -Raw | ConvertFrom-Json
        }
        
        It 'computes severity counts matching Group-Object' {
            $summary = Get-AuditorExecutiveSummary -Findings $findings
            
            $summary.severityCounts['Critical'] | Should -Be 3
            $summary.severityCounts['High'] | Should -Be 4
            $summary.severityCounts['Medium'] | Should -Be 2
            $summary.severityCounts['Low'] | Should -Be 1
        }
        
        It 'computes control-framework coverage from ComplianceMappings' {
            $summary = Get-AuditorExecutiveSummary -Findings $findings -ControlFrameworks @('CIS', 'NIST', 'MCSB', 'ISO27001')
            
            $summary.frameworkCoverage['CIS'].covered | Should -Be 9
            $summary.frameworkCoverage['CIS'].total | Should -Be 10
            $summary.frameworkCoverage['CIS'].pct | Should -Be 90.0
            
            $summary.frameworkCoverage['NIST'].covered | Should -Be 5
            $summary.frameworkCoverage['NIST'].total | Should -Be 10
            $summary.frameworkCoverage['NIST'].pct | Should -Be 50.0
            
            $summary.frameworkCoverage['MCSB'].covered | Should -Be 2
            $summary.frameworkCoverage['MCSB'].total | Should -Be 10
            $summary.frameworkCoverage['MCSB'].pct | Should -Be 20.0
            
            $summary.frameworkCoverage['ISO27001'].covered | Should -Be 1
            $summary.frameworkCoverage['ISO27001'].total | Should -Be 10
            $summary.frameworkCoverage['ISO27001'].pct | Should -Be 10.0
        }
    }
}
