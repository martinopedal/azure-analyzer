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
        $triagePath = Join-Path $fixtureDir 'triage.json'
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
    
    Context 'Get-AuditorAttackPathSection' {
        BeforeAll {
            $entities = Get-Content -Path $entitiesPath -Raw | ConvertFrom-Json
        }
        
        It 'returns attack-path count from entities.json' {
            $section = Get-AuditorAttackPathSection -Entities $entities -Tier 'EmbeddedSqlite'
            
            $section.TotalPaths | Should -Be 5
            $section.CriticalPaths | Should -BeGreaterOrEqual 0
        }
        
        It 'tier-aware rendering mode' {
            $sectionTier1 = Get-AuditorAttackPathSection -Entities $entities -Tier 'PureJson'
            $sectionTier4 = Get-AuditorAttackPathSection -Entities $entities -Tier 'PodeViewer'
            
            $sectionTier1.RenderingMode | Should -Be 'inline'
            $sectionTier4.RenderingMode | Should -Be 'deepLink'
        }
    }
    
    Context 'Get-AuditorResilienceSection' {
        BeforeAll {
            $entities = Get-Content -Path $entitiesPath -Raw | ConvertFrom-Json
        }
        
        It 'computes top 10 resources by blast-radius' {
            $section = Get-AuditorResilienceSection -Entities $entities -Tier 'EmbeddedSqlite'
            
            $section.TopResources.Count | Should -BeLessOrEqual 10
            $section.TopResources.Count | Should -BeGreaterThan 0
            
            $first = $section.TopResources[0]
            $last = $section.TopResources[-1]
            $first.BlastRadiusScore | Should -BeGreaterOrEqual $last.BlastRadiusScore
        }
    }
    
    Context 'Get-AuditorPolicyCoverageSection' {
        BeforeAll {
            $entities = Get-Content -Path $entitiesPath -Raw | ConvertFrom-Json
            $findings = Get-Content -Path $resultsPath -Raw | ConvertFrom-Json
        }
        
        It 'identifies missing policies' {
            $section = Get-AuditorPolicyCoverageSection -Entities $entities -Findings $findings
            
            $section.MissingCount | Should -BeGreaterThan 0
            @($section.GapSuggestions).Count | Should -BeGreaterThan 0
            $section.GapSuggestions.Count | Should -Be $section.MissingCount
        }
        
        It 'includes AzAdvertizer deep links' {
            $section = Get-AuditorPolicyCoverageSection -Entities $entities -Findings $findings
            
            $section.AzAdvertizerLinks.Count | Should -BeGreaterThan 0
            $section.AzAdvertizerLinks[0] | Should -Match 'azadvertizer\.net'
        }
    }
    
    Context 'Get-AuditorRemediationAppendix' {
        It 'groups by exact Remediation text' {
            $testFindings = @(
                [PSCustomObject]@{ FindingId = 'F1'; Severity = 'High'; Remediation = 'Enable MFA' }
                [PSCustomObject]@{ FindingId = 'F2'; Severity = 'High'; Remediation = 'Enable MFA' }
                [PSCustomObject]@{ FindingId = 'F3'; Severity = 'High'; Remediation = 'Enable MFA' }
                [PSCustomObject]@{ FindingId = 'F4'; Severity = 'Medium'; Remediation = 'Enable auditing' }
                [PSCustomObject]@{ FindingId = 'F5'; Severity = 'Medium'; Remediation = 'Enable auditing' }
                [PSCustomObject]@{ FindingId = 'F6'; Severity = 'Low'; Remediation = 'Add tags' }
                [PSCustomObject]@{ FindingId = 'F7'; Severity = 'Low'; Remediation = 'Add tags' }
                [PSCustomObject]@{ FindingId = 'F8'; Severity = 'Low'; Remediation = 'Add tags' }
                [PSCustomObject]@{ FindingId = 'F9'; Severity = 'Low'; Remediation = 'Add tags' }
                [PSCustomObject]@{ FindingId = 'F10'; Severity = 'High'; Remediation = 'Enable MFA' }
                [PSCustomObject]@{ FindingId = 'F11'; Severity = 'High'; Remediation = 'Enable MFA' }
                [PSCustomObject]@{ FindingId = 'F12'; Severity = 'High'; Remediation = 'Enable MFA' }
                [PSCustomObject]@{ FindingId = 'F13'; Severity = 'Medium'; Remediation = 'Enable auditing' }
                [PSCustomObject]@{ FindingId = 'F14'; Severity = 'Medium'; Remediation = 'Enable auditing' }
                [PSCustomObject]@{ FindingId = 'F15'; Severity = 'Medium'; Remediation = 'Enable auditing' }
            )
            
            $result = Get-AuditorRemediationAppendix -Findings $testFindings
            
            $result.RemediationGroups.Count | Should -Be 3
            ($result.RemediationGroups | Where-Object { $_.RemediationText -eq 'Enable MFA' }).TotalCount | Should -Be 6
            ($result.RemediationGroups | Where-Object { $_.RemediationText -eq 'Enable auditing' }).TotalCount | Should -Be 5
            ($result.RemediationGroups | Where-Object { $_.RemediationText -eq 'Add tags' }).TotalCount | Should -Be 4
        }
        
        It 'orders by severity weight descending' {
            $testFindings = @(
                [PSCustomObject]@{ FindingId = 'F1'; Severity = 'Low'; Remediation = 'Fix low' }
                [PSCustomObject]@{ FindingId = 'F2'; Severity = 'Critical'; Remediation = 'Fix critical' }
                [PSCustomObject]@{ FindingId = 'F3'; Severity = 'Medium'; Remediation = 'Fix medium' }
            )
            
            $result = Get-AuditorRemediationAppendix -Findings $testFindings
            
            $result.RemediationGroups.Count | Should -Be 3
            $result.RemediationGroups[0].MaxSeverity | Should -Be 'Critical'
            $result.RemediationGroups[1].MaxSeverity | Should -Be 'Medium'
            $result.RemediationGroups[2].MaxSeverity | Should -Be 'Low'
        }
    }
    
    Context 'Get-AuditorEvidenceExport' {
        BeforeAll {
            $testFindings = @(
                [PSCustomObject]@{ FindingId = 'F1'; Severity = 'High'; Title = 'Test finding 1' }
                [PSCustomObject]@{ FindingId = 'F2'; Severity = 'Medium'; Title = 'Test finding 2' }
                [PSCustomObject]@{ FindingId = 'F3'; Severity = 'Low'; Title = 'Test finding 3' }
                [PSCustomObject]@{ FindingId = 'F4'; Severity = 'High'; Title = 'Test finding 4' }
                [PSCustomObject]@{ FindingId = 'F5'; Severity = 'Critical'; Title = 'Test finding 5' }
            )
        }
        
        It 'writes CSV and JSON always' {
            $result = Get-AuditorEvidenceExport -Findings $testFindings -OutputDirectory $TestDrive
            
            $csvPath = Join-Path $TestDrive 'audit-evidence' 'findings.csv'
            $jsonPath = Join-Path $TestDrive 'audit-evidence' 'findings.json'
            
            Test-Path $csvPath | Should -Be $true
            Test-Path $jsonPath | Should -Be $true
            $result.ExportedFiles | Should -Contain $csvPath
            $result.ExportedFiles | Should -Contain $jsonPath
        }
        
        It 'writes XLSX only when ImportExcel present' {
            $importExcelPresent = $null -ne (Get-Module -ListAvailable -Name ImportExcel)
            
            $result = Get-AuditorEvidenceExport -Findings $testFindings -OutputDirectory $TestDrive
            
            $xlsxPath = Join-Path $TestDrive 'audit-evidence' 'findings.xlsx'
            
            if ($importExcelPresent) {
                $result.ExportedFiles | Should -Contain $xlsxPath -Because 'ImportExcel module is available'
            } else {
                $result.ExportedFiles | Should -Not -Contain $xlsxPath -Because 'ImportExcel module is not available'
            }
        }
        
        It 'sanitizes output via Remove-Credentials' {
            $unsafeFindings = @(
                [PSCustomObject]@{ 
                    FindingId = 'F1'; 
                    Severity = 'High'; 
                    Title = 'Exposed secret'; 
                    Details = 'Connection string contains password=secret123 and key=abc'
                }
            )
            
            $result = Get-AuditorEvidenceExport -Findings $unsafeFindings -OutputDirectory $TestDrive
            
            $csvPath = Join-Path $TestDrive 'audit-evidence' 'findings.csv'
            $csvContent = Get-Content $csvPath -Raw
            
            $csvContent | Should -Not -Match 'secret123' -Because 'Remove-Credentials should redact the password'
        }
    }
    
    Context 'Get-AuditorTriageAnnotations' {
        BeforeAll {
            $findings = Get-Content -Path $resultsPath -Raw | ConvertFrom-Json
        }
        
        It 'joins triage verdicts when present' {
            $result = Get-AuditorTriageAnnotations -Findings $findings -TriagePath $triagePath
            
            $result.TriagePresent | Should -Be $true
            $result.AnnotatedFindings.Count | Should -Be $findings.Count
            
            $withVerdict = @($result.AnnotatedFindings | Where-Object { $null -ne $_.Verdict })
            $withoutVerdict = @($result.AnnotatedFindings | Where-Object { $null -eq $_.Verdict })
            
            $withVerdict.Count | Should -Be 5
            $withoutVerdict.Count | Should -Be ($findings.Count - 5)
        }
        
        It 'degrades gracefully when triage.json missing' {
            $result = Get-AuditorTriageAnnotations -Findings $findings -TriagePath ''
            
            $result.TriagePresent | Should -Be $false
            $result.AnnotatedFindings.Count | Should -Be $findings.Count
            
            { Get-AuditorTriageAnnotations -Findings $findings -TriagePath $null } | Should -Not -Throw
            { Get-AuditorTriageAnnotations -Findings $findings -TriagePath 'nonexistent.json' } | Should -Not -Throw
        }
        
        It 'includes suggested suppression when Track E provides it' {
            $result = Get-AuditorTriageAnnotations -Findings $findings -TriagePath $triagePath
            
            $findingWithSuppression = $result.AnnotatedFindings | Where-Object { $_.FindingId -eq 'F-005' } | Select-Object -First 1
            
            $findingWithSuppression | Should -Not -BeNullOrEmpty
            $findingWithSuppression.SuggestedSuppression | Should -Be 'false_positive'
        }
    }
    
    Context 'Write-AuditorRenderTier' {
        BeforeAll {
            $context = Resolve-AuditorContext -InputPath $resultsPath -EntitiesPath $entitiesPath -ManifestPath $manifestPath
        }
        
        It 'produces HTML and MD files' {
            $result = Write-AuditorRenderTier -Context $context -OutputDirectory $TestDrive -Tier 'EmbeddedSqlite'
            
            $htmlPath = Join-Path $TestDrive 'audit-report.html'
            $mdPath = Join-Path $TestDrive 'audit-report.md'
            
            Test-Path $htmlPath | Should -Be $true
            Test-Path $mdPath | Should -Be $true
            $result.HtmlPath | Should -Be $htmlPath
            $result.MdPath | Should -Be $mdPath
            $result.RenderingMode | Should -Not -BeNullOrEmpty
        }
        
        It 'tier-aware rendering mode' {
            $resultTier1 = Write-AuditorRenderTier -Context $context -OutputDirectory (Join-Path $TestDrive 'tier1') -Tier 'PureJson'
            $resultTier4 = Write-AuditorRenderTier -Context $context -OutputDirectory (Join-Path $TestDrive 'tier4') -Tier 'PodeViewer'
            
            $htmlTier1 = Get-Content $resultTier1.HtmlPath -Raw
            $htmlTier4 = Get-Content $resultTier4.HtmlPath -Raw
            
            $htmlTier1 | Should -Match '<table'
            $htmlTier4 | Should -Match '<a href'
            $htmlTier4 | Should -Match 'kpi-grid'
            
            $resultTier1.RenderingMode | Should -Be 'Tier1Full'
            $resultTier4.RenderingMode | Should -Be 'Tier4KPIs'
        }
    }
    
    Context 'New-AuditorCitation' {
        It 'produces single-line workpaper-ready string' {
            $finding = [PSCustomObject]@{
                Source = 'azsk'
                RulePin = '1.2.3'
                Id = 'F-123'
                Title = 'Insecure NSG'
                CanonicalId = '/subscriptions/test-sub/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/nsg-foo'
                Severity = 'High'
                CollectedAtUtc = '2025-01-01T00:00:00Z'
            }
            
            $citation = New-AuditorCitation -Finding $finding
            
            $citation | Should -Match '\[azsk 1\.2\.3\]'
            $citation | Should -Match 'F-123: Insecure NSG'
            $citation | Should -Match 'Severity: High'
            $citation | Should -Not -Match "`n"
        }
        
        It 'sanitizes credentials via Remove-Credentials' {
            $finding = [PSCustomObject]@{
                Id = 'F-SECRET'
                Title = 'Exposed connection string with password=secret123 in code'
                Severity = 'Critical'
                EntityId = '/subscriptions/test-sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st01'
            }
            
            $citation = New-AuditorCitation -Finding $finding
            
            $citation | Should -Not -Match 'secret123'
            $citation | Should -Match '\[REDACTED\]'
        }
    }
}
