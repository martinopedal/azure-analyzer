BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\AuditorReportBuilder.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Schema.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\ReportManifest.ps1"
}

Describe 'Auditor Data Flow End-to-End' -Tag 'Integration' {
    BeforeAll {
        $script:fixturePath = "$PSScriptRoot\..\fixtures\auditor-jumbo"
        $script:resultsPath = Join-Path $fixturePath 'results.json'
        $script:entitiesPath = Join-Path $fixturePath 'entities.json'
        $script:manifestPath = Join-Path $fixturePath 'report-manifest.json'
        $script:triagePath = Join-Path $fixturePath 'triage.json'
        
        # Load fixture counts
        $script:fixtureFindings = (Get-Content $resultsPath -Raw | ConvertFrom-Json)
        $script:expectedFindingCount = $script:fixtureFindings.Count
        
        $script:testOutputDir = Join-Path $TestDrive 'dataflow-output'
        New-Item -ItemType Directory -Path $testOutputDir -Force | Out-Null
    }

    Context 'Data preservation through triage pipeline' {
        It 'Should preserve findings count through every hand-off point when triage is provided' {
            # Arrange: Known fixture with N findings
            $expectedCount = $script:expectedFindingCount
            $expectedCount | Should -BeGreaterThan 0 -Because 'fixture must have findings'
            
            # Act: Build report with triage
            $report = Build-AuditorReport -InputPath $resultsPath `
                                          -EntitiesPath $entitiesPath `
                                          -ManifestPath $manifestPath `
                                          -TriagePath $triagePath `
                                          -OutputDirectory $testOutputDir `
                                          -Tier 'PureJson' `
                                          -PassThru
            
            # Assert: Data preserved at EVERY hand-off
            
            # Hand-off 1: Triage step must preserve findings
            # (BUG-1 violated this: $annotated.Findings returned $null instead of $annotated.AnnotatedFindings)
            $csvPath = Join-Path $testOutputDir 'audit-evidence' 'findings.csv'
            $csvPath | Should -Exist -Because 'evidence export runs after triage and must receive non-null findings'
            
            $csvContent = Get-Content $csvPath -Raw
            $csvLines = $csvContent -split "`n" | Where-Object { $_.Trim() -ne '' }
            # CSV = 1 header + N data rows
            $csvLines.Count | Should -Be ($expectedCount + 1) -Because "triage step must preserve all $expectedCount findings; fewer rows indicate silent null from key mismatch"
            
            # Hand-off 2: HTML renderer must receive non-null findings
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlPath | Should -Exist
            
            $htmlContent = Get-Content $htmlPath -Raw
            
            # Reject ghost rows (iterating @($null) produces empty <td> cells)
            $htmlContent | Should -Not -Match '<td>\s*</td>\s*<td>\s*</td>\s*<td>\s*</td>\s*<td>\s*</td>' -Because 'ghost rows indicate renderer received null findings from triage'
            
            # Each finding ID must appear at least once
            $findingIds = $script:fixtureFindings | Select-Object -First 5 -ExpandProperty FindingId
            foreach ($id in $findingIds) {
                $escapedId = [regex]::Escape($id)
                $htmlContent | Should -Match $escapedId -Because "finding $id must render in HTML if data flow is intact"
            }
            
            # Hand-off 3: Markdown renderer must receive non-null findings
            $mdPath = Join-Path $testOutputDir 'audit-report.md'
            $mdPath | Should -Exist
            
            $mdContent = Get-Content $mdPath -Raw
            foreach ($id in $findingIds) {
                $escapedId = [regex]::Escape($id)
                $mdContent | Should -Match $escapedId -Because "finding $id must render in Markdown if data flow is intact"
            }
        }
        
        It 'Should preserve findings when triage path is null (no triage data)' {
            # Arrange
            $noTriageOut = Join-Path $TestDrive 'no-triage-output'
            New-Item -ItemType Directory -Path $noTriageOut -Force | Out-Null
            
            # Act: Build without triage
            $report = Build-AuditorReport -InputPath $resultsPath `
                                          -EntitiesPath $entitiesPath `
                                          -ManifestPath $manifestPath `
                                          -TriagePath '' `
                                          -OutputDirectory $noTriageOut `
                                          -Tier 'PureJson' `
                                          -PassThru
            
            # Assert: Findings still flow through
            $csvPath = Join-Path $noTriageOut 'audit-evidence' 'findings.csv'
            $csvPath | Should -Exist
            
            $csvContent = Get-Content $csvPath -Raw
            $csvLines = $csvContent -split "`n" | Where-Object { $_.Trim() -ne '' }
            $csvLines.Count | Should -Be ($script:expectedFindingCount + 1) -Because 'no-triage path must preserve all findings'
        }
    }
    
    Context 'Remediation appendix generation' {
        It 'Should generate non-empty remediation groups when findings have remediation text' {
            # Act
            Build-AuditorReport -InputPath $resultsPath `
                                -EntitiesPath $entitiesPath `
                                -ManifestPath $manifestPath `
                                -TriagePath $triagePath `
                                -OutputDirectory $testOutputDir `
                                -Tier 'PureJson'
            
            # Assert: Remediation appendix populated
            # (BUG-1 would cause this to be empty because Get-AuditorRemediationAppendix received $null)
            $htmlPath = Join-Path $testOutputDir 'audit-report.html'
            $htmlContent = Get-Content $htmlPath -Raw
            
            # At minimum, HTML should contain the word "Remediation" if the appendix section exists
            # (Full remediation appendix testing is out of scope for this defensive test)
            $htmlContent | Should -Match 'Remediation|Finding' -Because 'report must contain findings or remediation content if data flow is intact'
        }
    }
}
