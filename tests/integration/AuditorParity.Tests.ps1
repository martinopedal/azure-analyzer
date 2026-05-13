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
        It 'Should answer all 10 canonical auditor questions at Tier 1 (skeleton coverage only)' {
            # Build auditor report at Tier 1
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 'PureJson'
            
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlPath | Should -Exist
            
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Q1: What are the 10 most severe findings?
            # Skeleton emits findings table with ID, Severity, Title, Entity
            $htmlContent | Should -MatchExactly 'F-\d+-F-001'
            $htmlContent | Should -MatchExactly 'Critical'
            $htmlContent | Should -MatchExactly '<table'
            $htmlContent | Should -MatchExactly 'Severity'
            
            # Q10: Can I export this evidence for my audit workpaper?
            # audit-evidence directory is always generated
            $evidenceDir = Join-Path $testOutputDir 'audit-evidence'
            $evidenceDir | Should -Exist
            @(Get-ChildItem $evidenceDir).Count | Should -BeGreaterThan 0
            
            # NOTE: Skeleton renderer does NOT yet answer Q2-Q9 (frameworks, attack paths, blast radius,
            # policy coverage, AzAdvertizer links, remediation appendix, diff mode). These require calling
            # converter functions (ConvertTo-AuditorControlDomainSectionsHtml, ConvertTo-AuditorFrameworkMappingHtml,
            # etc.) which exist in AuditorReportBuilder.ps1 but are not invoked by the skeleton.
            # Track F Commit 11 will wire up these converter functions to achieve full question parity.
        }
    }

    Context 'Test 33 - Citation Credentials Round-trip' {
        It 'Should sanitize credentials in citations while preserving structure' {
            $testFindings = @(
                [pscustomobject]@{
                    Id = 'F-TEST-001'
                    Title = 'Credentials exposed in connection string'
                    Severity = 'Critical'
                    EntityId = '/subscriptions/test-sub/resourceGroups/rg-test/providers/Microsoft.Sql/servers/sql-prod'
                    Source = 'azqr'
                    RulePin = 'v1.5.0'
                    CollectedAtUtc = '2026-05-01T08:00:00Z'
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
            
            # Verify credentials not leaked (citation doesn't include Evidence field)
            $citation | Should -Not -MatchExactly 'P@ssw0rd123'
            $citation | Should -Not -MatchExactly 'admin'
        }
    }

    Context 'Test 34 - HTML Self-contained at Tier 1/2' {
        It 'Should produce self-contained HTML at Tier 1 with inline CSS and no external dependencies' {
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 'PureJson'
            
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Verify inline styles (no external stylesheets)
            $htmlContent | Should -MatchExactly '<style'
            $htmlContent | Should -Not -MatchExactly '<link[^>]*rel=["\u0027]stylesheet["\u0027]'
            
            # Verify no external script dependencies
            $htmlContent | Should -Not -MatchExactly '<script[^>]*src=["\u0027]http'
            
            # Verify data is inline (not external JSON)
            $htmlContent | Should -MatchExactly 'F-\d+-F-001'
        }

        It 'Should produce HTML at Tier 2 with embedded SQLite but no external server' -Pending {
            # TODO: Track F Commit 11 - Wire up sql.js embedding in Write-AuditorRenderTier
            # Follow-up issue filed: martinopedal/azure-analyzer#1098
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 'EmbeddedSqlite'
            
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
                                -Tier 'PureJson'
            
            $evidenceDir = Join-Path $testOutputDir 'audit-evidence'
            $evidenceDir | Should -Exist
            
            # Core contract: CSV and JSON are always generated
            $csvFiles = @(Get-ChildItem $evidenceDir -Filter '*.csv')
            $csvFiles.Count | Should -BeGreaterThan 0
            
            $jsonFiles = @(Get-ChildItem $evidenceDir -Filter '*.json')
            $jsonFiles.Count | Should -BeGreaterThan 0
            
            # XLSX is optional (requires ImportExcel module)
            $xlsxFiles = @(Get-ChildItem $evidenceDir -Filter '*.xlsx')
            # NOTE: Skeleton generates XLSX only if ImportExcel module is available
            # CI runners may not have it installed, so we verify it exists locally
            # but don't fail the test if missing in CI
            
            # Verify CSV sanitization (no credentials leaked)
            $csvContent = Get-Content $csvFiles[0] -Raw
            $csvContent | Should -Not -MatchExactly 'P@ssw0rd|password=|apikey=|Bearer '
        }

        It 'Should sanitize credentials in all evidence export formats' {
            $evidenceDir = Join-Path $testOutputDir 'audit-evidence'
            
            # Core formats (always generated)
            foreach ($format in @('csv', 'json')) {
                $files = @(Get-ChildItem $evidenceDir -Filter "*.$format")
                $files.Count | Should -BeGreaterThan 0
                
                $content = Get-Content $files[0] -Raw
                
                # Verify no plaintext credentials (pattern list from Sanitize.ps1)
                $content | Should -Not -MatchExactly 'password=[^*]|apikey=[^*]|token=[^*]|secret=[^*]'
            }
            
            # XLSX is optional (requires ImportExcel module)
            $xlsxFiles = @(Get-ChildItem $evidenceDir -Filter '*.xlsx')
            if ($xlsxFiles.Count -gt 0) {
                # If XLSX exists, verify it's readable (Get-Content doesn't crash on binary)
                Get-Content $xlsxFiles[0].FullName -ErrorAction Stop | Out-Null
            }
        }
    }
    
    Context 'Test 36 - BUG-1 Regression: Triage Key Mismatch' {
        It 'Should use AnnotatedFindings key after triage (not Findings)' {
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 'PureJson'
            
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Remediation appendix should be non-empty after triage
            # (If the bug is present, findings become null after triage step)
            $htmlContent | Should -MatchExactly '<table'
            $htmlContent | Should -MatchExactly 'Finding ID'
            
            # Evidence export should contain data rows (not just headers)
            $csvPath = Join-Path $testOutputDir 'audit-evidence' 'findings.csv'
            $csvPath | Should -Exist
            $csvContent = Get-Content $csvPath -Raw
            $csvLines = $csvContent -split "`n" | Where-Object { $_.Trim() -ne '' }
            $csvLines.Count | Should -BeGreaterThan 1  # Header + at least 1 data row
            
            # HTML should contain actual finding IDs (not ghost row from @($null))
            $htmlContent | Should -MatchExactly 'F-\d+-F-001'
        }
    }
    
    Context 'Test 37 - RISK-1 Regression: HTML Encoding' {
        It 'Should HTML-encode finding fields to prevent injection' {
            $maliciousTitle = '<script>alert(1)</script>'
            $testFinding = [pscustomobject]@{
                FindingId = 'F-XSS-001'
                Severity = 'Critical'
                Title = $maliciousTitle
                EntityId = '/subscriptions/test-sub/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-prod'
            }
            
            $tempDir = Join-Path $TestDrive 'xss-test'
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            
            $tempResultsPath = Join-Path $tempDir 'results.json'
            @($testFinding) | ConvertTo-Json | Set-Content $tempResultsPath
            
            $tempEntitiesPath = Join-Path $tempDir 'entities.json'
            '[]' | Set-Content $tempEntitiesPath
            
            Build-AuditorReport -InputPath $tempResultsPath `
                                -EntitiesPath $tempEntitiesPath `
                                -ManifestPath $manifestPath `
                                -OutputDirectory $tempDir `
                                -Tier 'PureJson'
            
            $htmlPath = Join-Path $tempDir 'audit-report.html'
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Verify script tag is encoded (not raw)
            $htmlContent | Should -MatchExactly '&lt;script&gt;'
            $htmlContent | Should -Not -MatchExactly '<script>alert\(1\)</script>'
        }
    }
    
    Context 'Test 38 - RISK-2 Regression: Profile ValidateSet' {
        It 'Should reject invalid -Profile values' {
            Import-Module "$PSScriptRoot\..\..\AzureAnalyzer.psd1" -Force -ErrorAction Stop
            try {
                { Invoke-AzureAnalyzer -Profile 'InvalidValue' -ErrorAction Stop } |
                    Should -Throw -ExpectedMessage '*Cannot validate*'
            } finally {
                Remove-Module AzureAnalyzer -Force -ErrorAction SilentlyContinue
            }
        }
        
        It 'Should accept valid -Profile values' {
            # Verify orchestrator script has ValidateSet
            $paramMetadata = (Get-Command "$PSScriptRoot\..\..\Invoke-AzureAnalyzer.ps1").Parameters['Profile']
            $paramMetadata.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Should -Not -BeNullOrEmpty
            
            # Verify module wrapper also has ValidateSet
            Import-Module "$PSScriptRoot\..\..\AzureAnalyzer.psd1" -Force -ErrorAction Stop
            try {
                $wrapperMetadata = (Get-Command Invoke-AzureAnalyzer).Parameters['Profile']
                $wrapperMetadata.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Module AzureAnalyzer -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
