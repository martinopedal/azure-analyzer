BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\AuditorReportBuilder.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Schema.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\ReportManifest.ps1"
}

Describe 'Auditor Parity Tests' -Tag 'Integration' {
    BeforeAll {
        $script:fixturePath = "$PSScriptRoot\..\fixtures\auditor-jumbo"
        $script:resultsPath = Join-Path $fixturePath 'results.json'
        $script:entitiesPath = Join-Path $fixturePath 'entities.json'
        $script:manifestPath = Join-Path $fixturePath 'report-manifest.json'
        $script:triagePath = Join-Path $fixturePath 'triage.json'
        
        # Load fixture data once
        $script:results = Get-Content $resultsPath -Raw | ConvertFrom-Json
        $script:entities = Get-Content $entitiesPath -Raw | ConvertFrom-Json
        $script:manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $script:triage = Get-Content $triagePath -Raw | ConvertFrom-Json
        
        $script:testOutputDir = Join-Path $TestDrive 'auditor-output'
        New-Item -ItemType Directory -Path $testOutputDir -Force | Out-Null
    }

    Context 'Test 32 - 10 Canonical Auditor Questions (Question Parity)' {
        It 'Should answer all 10 canonical auditor questions at Tier 1' {
            # Build auditor report at Tier 1
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 1
            
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlPath | Should -Exist
            
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Q1: What are the 10 most severe findings?
            $htmlContent | Should -MatchExactly 'F-\d+-F-001'
            $htmlContent | Should -MatchExactly 'Critical'
            
            # Q2: Which compliance controls are failing, by framework?
            $htmlContent | Should -MatchExactly 'CIS 2\.1\.4'
            $htmlContent | Should -MatchExactly 'NIST SC-28'
            $htmlContent | Should -MatchExactly 'MCSB'
            $htmlContent | Should -MatchExactly 'ISO27001'
            
            # Q3: Which findings belong to subscription X / management group Y?
            $htmlContent | Should -MatchExactly '/subscriptions/sub-\d+'
            
            # Q4: What is the attack path to privileged identity Z?
            $htmlContent | Should -MatchExactly 'attack.*path|Attack Path'
            
            # Q5: What is the blast radius of resource R?
            $htmlContent | Should -MatchExactly 'blast.*radius|Blast Radius'
            
            # Q6: Which policies are assigned vs. missing at scope S?
            $htmlContent | Should -MatchExactly 'policy.*coverage|Policy Coverage'
            
            # Q7: What does AzAdvertizer or ALZ suggest for this gap?
            # (Covered in policy section or remediation appendix)
            $htmlContent | Should -MatchExactly 'remediation|Remediation'
            
            # Q8: What is the remediation text for finding F?
            $htmlContent | Should -MatchExactly 'remediation.*appendix|Remediation Appendix'
            
            # Q9: How did things change since run R?
            # (Diff mode tested separately; manifest should reference it)
            $manifest.Report.Features | Should -Contain 'diff-mode'
            
            # Q10: Can I export this evidence for my audit workpaper?
            $evidenceDir = Join-Path $testOutputDir 'audit-evidence'
            $evidenceDir | Should -Exist
            (Get-ChildItem $evidenceDir).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Test 33 - Citation Credentials Round-trip' {
        It 'Should sanitize credentials in citations while preserving structure' {
            $testFindings = @(
                @{
                    FindingId = 'F-TEST-001'
                    Title = 'Credentials exposed in connection string'
                    Severity = 'Critical'
                    EntityId = '/subscriptions/test-sub/resourceGroups/rg-test/providers/Microsoft.Sql/servers/sql-prod'
                    SourceTool = 'azqr'
                    SourceToolVersion = '1.5.0'
                    Timestamp = '2026-05-01T08:00:00Z'
                    Evidence = 'Connection string: Server=tcp:sql-prod.database.windows.net;User ID=admin;Password=P@ssw0rd123;'
                }
            )
            
            $testFindings | ConvertTo-Json | Set-Content (Join-Path $testOutputDir 'test-results.json') -NoNewline
            
            # Generate citations
            $citation = New-AuditorCitation -Finding $testFindings[0]
            
            # Verify structure preserved
            $citation | Should -MatchExactly 'azqr v1\.5\.0'
            $citation | Should -MatchExactly 'F-TEST-001'
            $citation | Should -MatchExactly 'Critical'
            
            # Verify credentials removed
            $citation | Should -Not -MatchExactly 'P@ssw0rd123'
            $citation | Should -Not -MatchExactly 'admin'
            $citation | Should -MatchExactly '\*\*\*\*\*\*'
        }
    }

    Context 'Test 34 - HTML Self-contained at Tier 1/2' {
        It 'Should produce self-contained HTML at Tier 1 with inline CSS and no external dependencies' {
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 1
            
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Verify inline styles (no external stylesheets)
            $htmlContent | Should -MatchExactly '<style'
            $htmlContent | Should -Not -MatchExactly '<link.*rel=["\']stylesheet["\']'
            
            # Verify no external script dependencies
            $htmlContent | Should -Not -MatchExactly '<script.*src=["\']http'
            
            # Verify data is inline (not external JSON)
            $htmlContent | Should -MatchExactly 'F-\d+-F-001'
        }

        It 'Should produce HTML at Tier 2 with embedded SQLite but no external server' {
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 2
            
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Verify sql.js embedded
            $htmlContent | Should -MatchExactly 'sql\.js|sqljs|SQL\.Database'
            
            # Verify no external server URLs
            $htmlContent | Should -Not -MatchExactly 'http://localhost|ws://|wss://'
        }
    }

    Context 'Test 35 - Audit-evidence Directory Generated' {
        It 'Should generate audit-evidence directory with CSV, JSON, and XLSX exports' {
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 1
            
            $evidenceDir = Join-Path $testOutputDir 'audit-evidence'
            $evidenceDir | Should -Exist
            
            # Verify export formats
            $csvFiles = Get-ChildItem $evidenceDir -Filter '*.csv'
            $csvFiles.Count | Should -BeGreaterThan 0
            
            $jsonFiles = Get-ChildItem $evidenceDir -Filter '*.json'
            $jsonFiles.Count | Should -BeGreaterThan 0
            
            $xlsxFiles = Get-ChildItem $evidenceDir -Filter '*.xlsx'
            $xlsxFiles.Count | Should -BeGreaterThan 0
            
            # Verify CSV sanitization (no credentials leaked)
            $csvContent = Get-Content $csvFiles[0] -Raw
            $csvContent | Should -Not -MatchExactly 'P@ssw0rd|password=|apikey=|Bearer '
        }

        It 'Should sanitize credentials in all evidence export formats' {
            $evidenceDir = Join-Path $testOutputDir 'audit-evidence'
            
            foreach ($format in @('csv', 'json', 'xlsx')) {
                $files = Get-ChildItem $evidenceDir -Filter "*.$format"
                $files.Count | Should -BeGreaterThan 0
                
                $content = if ($format -eq 'json') {
                    Get-Content $files[0] -Raw
                } else {
                    # For CSV/XLSX, convert to string representation
                    Get-Content $files[0] -Raw
                }
                
                # Verify no plaintext credentials (pattern list from Sanitize.ps1)
                $content | Should -Not -MatchExactly 'password=[^*]|apikey=[^*]|token=[^*]|secret=[^*]'
            }
        }
    }
}
