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
            
            $context.Findings.Count | Should -Be 32
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
            
            $summary.severityCounts['Critical'] | Should -Be 4
            $summary.severityCounts['High'] | Should -Be 14
            $summary.severityCounts['Medium'] | Should -Be 10
            $summary.severityCounts['Low'] | Should -Be 4
        }
        
        It 'computes control-framework coverage from ComplianceMappings' {
            $summary = Get-AuditorExecutiveSummary -Findings $findings -ControlFrameworks @('CIS', 'NIST', 'MCSB', 'ISO27001')
            
            $summary.frameworkCoverage['CIS'].covered | Should -BeGreaterOrEqual 9
            $summary.frameworkCoverage['NIST'].covered | Should -BeGreaterOrEqual 5
            $summary.frameworkCoverage['MCSB'].covered | Should -BeGreaterOrEqual 2
            $summary.frameworkCoverage['ISO27001'].covered | Should -BeGreaterOrEqual 1
        }
    }
    
    Context 'Get-AuditorControlDomainSections' {
        BeforeAll {
            $findings = Get-Content -Path $resultsPath -Raw | ConvertFrom-Json
        }
        
        It 'groups findings by framework control id' {
            $sections = Get-AuditorControlDomainSections -Findings $findings -Frameworks @('CIS', 'NIST', 'MCSB', 'ISO27001')
            
            $sections.Count | Should -BeGreaterThan 0
            
            $cisSections = $sections | Where-Object { $_.Framework -eq 'CIS' -and $_.ControlId -eq '2.1.1' }
            $cisSections.Count | Should -Be 1
            $cisSections[0].FindingCount | Should -Be 10
            
            $nistSections = $sections | Where-Object { $_.Framework -eq 'NIST' -and $_.ControlId -eq 'AC-2' }
            $nistSections.Count | Should -Be 1
            $nistSections[0].FindingCount | Should -Be 8
            
            $mcsbSections = $sections | Where-Object { $_.Framework -eq 'MCSB' -and $_.ControlId -eq 'IM-1' }
            $mcsbSections.Count | Should -Be 1
            $mcsbSections[0].FindingCount | Should -Be 7
            
            $isoSections = $sections | Where-Object { $_.Framework -eq 'ISO27001' -and $_.ControlId -eq 'A.9.2' }
            $isoSections.Count | Should -Be 1
            $isoSections[0].FindingCount | Should -Be 5
        }
        
        It 'handles missing ComplianceMappings gracefully' {
            $testFindings = @(
                [PSCustomObject]@{ FindingId = 'T1'; ComplianceMappings = @('CIS 1.1'); Severity = 'High' }
                [PSCustomObject]@{ FindingId = 'T2'; ComplianceMappings = $null; Severity = 'High' }
                [PSCustomObject]@{ FindingId = 'T3'; ComplianceMappings = @('CIS 1.1'); Severity = 'Medium' }
                [PSCustomObject]@{ FindingId = 'T4'; Severity = 'Low' }
                [PSCustomObject]@{ FindingId = 'T5'; ComplianceMappings = @('CIS 1.1'); Severity = 'High' }
            )
            
            { Get-AuditorControlDomainSections -Findings $testFindings -Frameworks @('CIS') } | Should -Not -Throw
            
            $sections = Get-AuditorControlDomainSections -Findings $testFindings -Frameworks @('CIS')
            $sections.Count | Should -Be 1
            $sections[0].FindingCount | Should -Be 3
        }
        
        It 'renders HTML table per framework' {
            $testFindings = @(
                [PSCustomObject]@{ FindingId = 'T1'; ComplianceMappings = @('CIS 2.1.1'); Severity = 'High'; Title = 'Test 1' }
                [PSCustomObject]@{ FindingId = 'T2'; ComplianceMappings = @('CIS 2.1.1'); Severity = 'High'; Title = 'Test 2' }
            )
            
            $sections = Get-AuditorControlDomainSections -Findings $testFindings -Frameworks @('CIS')
            $html = ConvertTo-AuditorControlDomainSectionsHtml -Sections $sections
            
            $html | Should -Match '<table'
            $html | Should -Match '<tr>'
            $html | Should -Match 'CIS'
            $html | Should -Match '2\.1\.1'
        }
    }
}
