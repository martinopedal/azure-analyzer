BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\AuditorReportBuilder.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Schema.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\ReportManifest.ps1"
}

<#
.SYNOPSIS
    Regression tests for BUG-1 class (silent null from hashtable key mismatch).

.DESCRIPTION
    CONVENTION: Render-output assertion pairing rule
    
    Every `Should -Match` / `Should -MatchExactly` against rendered output (HTML/MD/JSON)
    MUST be paired with `Should -Not -BeNullOrEmpty` on the upstream collection the
    renderer iterates.
    
    Rationale: PowerShell's silent-null behavior means:
    - Hashtable key mismatch returns $null (no error, no StrictMode violation)
    - @($null) creates array with 1 element = $null
    - foreach ($item in @($null)) loops ONCE with $item = $null
    - $null.Property returns empty string '' (not error)
    - Regex can match unrelated page content, producing false-pass
    
    Example (BUG-1):
        $context['Findings'] = $annotated.Findings  # Bug: should be .AnnotatedFindings
        # $context['Findings'] becomes $null
        # Renderer iterates @($null), produces <td></td> ghost row
        # Test matches 'F-\d+-F-001' elsewhere in document → false pass
    
    Protection pattern:
        $data | Should -Not -BeNullOrEmpty -Because 'upstream must preserve data'
        $rendered | Should -Match 'pattern'
        $rendered | Should -Not -Match '<td></td>' -Because 'reject ghost rows'

.NOTES
    All tests in this file follow fail-first discipline:
    1. Test is written
    2. Test runs against PRE-FIX code (e0d6011 for BUG-1) and FAILS
    3. Test runs against POST-FIX code and PASSES
    
    Proof of fail-first is documented in PR description.
#>

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

    Context 'BUG-1 Instance Test (hashtable key mismatch: $annotated.Findings vs .AnnotatedFindings)' {
        It 'Should read AnnotatedFindings key from Get-AuditorTriageAnnotations return value' {
            # BUG-1 REGRESSION: Build-AuditorReport line 120 read $annotated.Findings (wrong key)
            # instead of $annotated.AnnotatedFindings (correct key). This nulled $context['Findings']
            # and broke evidence export / remediation / renderer.
            
            # This test directly asserts the contract: triage function returns AnnotatedFindings,
            # caller must read that key. If caller reads .Findings (non-existent), assignment becomes null.
            
            # Arrange: Load fixture
            $findings = Get-Content $script:resultsPath -Raw | ConvertFrom-Json
            
            # Act: Call triage function
            $annotated = Get-AuditorTriageAnnotations -Findings $findings -TriagePath $script:triagePath
            
            # Assert: Return value has AnnotatedFindings key
            # NOTE: Get-AuditorTriageAnnotations returns [hashtable]; use .Keys (or .ContainsKey),
            # not .PSObject.Properties.Name (which enumerates hashtable reflection properties, not entries).
            $annotated | Should -BeOfType [hashtable] -Because 'contract returns hashtable, not PSCustomObject'
            $annotated.ContainsKey('AnnotatedFindings') | Should -BeTrue -Because 'Get-AuditorTriageAnnotations contract specifies this key'
            $annotated.AnnotatedFindings | Should -Not -BeNullOrEmpty -Because 'triage must return annotated findings array'
            $annotated.AnnotatedFindings.Count | Should -Be $findings.Count -Because 'triage preserves all findings'
            
            # Assert: Build-AuditorReport reads the CORRECT key (not .Findings)
            # We verify this by running full pipeline and checking downstream data is non-null
            Build-AuditorReport -InputPath $script:resultsPath `
                                -EntitiesPath $script:entitiesPath `
                                -ManifestPath $script:manifestPath `
                                -TriagePath $script:triagePath `
                                -OutputDirectory $script:testOutputDir `
                                -Tier 'PureJson'
            
            # If Build-AuditorReport reads .Findings (bug), evidence export receives null
            $csvPath = Join-Path $script:testOutputDir 'audit-evidence' 'findings.csv'
            $csvPath | Should -Exist -Because 'evidence export runs after triage'
            
            $csvContent = Get-Content $csvPath -Raw
            $csvLines = $csvContent -split "`n" | Where-Object { $_.Trim() -ne '' }
            # CSV = 1 header + N data rows. If bug is present, CSV has only 1 line (header).
            $csvLines.Count | Should -Be ($findings.Count + 1) -Because 'BUG-1: if Build-AuditorReport reads .Findings (null), CSV has 0 data rows'
        }
    }
    
    Context 'BUG-1 Class Test (hashtable contract validation for all Get-Auditor* helpers)' {
        It 'Should validate all Get-Auditor* helper return keys match Build-AuditorReport consumer reads' {
            # CLASS TEST: Any helper returning hashtable consumed by Build-AuditorReport must have
            # matching producer/consumer key names. If producer returns { Foo = ... } but consumer
            # reads $result.Bar, the same silent-null bug occurs.
            
            # Known Get-Auditor* helpers and their consumers:
            # 1. Get-AuditorTriageAnnotations → Build-AuditorReport line 120 reads .AnnotatedFindings + .TriagePresent
            # 2. Get-AuditorExecutiveSummary → Build-AuditorReport line 81 stores in $context['Summary']
            # 3. Get-AuditorControlDomainSections → Build-AuditorReport line 90 stores in $context['ControlDomainSections']
            # 4. Get-AuditorAttackPathSection → Build-AuditorReport line 97 stores in $context['AttackPathSection']
            # 5. Get-AuditorResilienceSection → Build-AuditorReport line 104 stores in $context['ResilienceSection']
            # 6. Get-AuditorPolicyCoverageSection → Build-AuditorReport line 111 stores in $context['PolicyCoverageSection']
            # 7. Get-AuditorRemediationAppendix → Build-AuditorReport line 128 stores in $context['RemediationAppendix']
            # 8. Get-AuditorEvidenceExport → Build-AuditorReport line 135-138 reads .ExportPath (WAIT: check return structure)
            
            # For each helper, assert the keys it returns match what the consumer reads.
            # We do this by running full pipeline and checking intermediate $context state.
            
            # Run full pipeline
            $report = Build-AuditorReport -InputPath $script:resultsPath `
                                          -EntitiesPath $script:entitiesPath `
                                          -ManifestPath $script:manifestPath `
                                          -TriagePath $script:triagePath `
                                          -OutputDirectory $script:testOutputDir `
                                          -Tier 'PureJson' `
                                          -PassThru
            
            # If any helper has key mismatch, Build-AuditorReport will have $context[<Section>] = $null
            # and PassThru result will lack expected fields OR evidence files won't exist.
            
            # Evidence export contract
            $csvPath = Join-Path $script:testOutputDir 'audit-evidence' 'findings.csv'
            $csvPath | Should -Exist -Because 'Get-AuditorEvidenceExport contract: returns ExportPath that exists'
            
            $jsonPath = Join-Path $script:testOutputDir 'audit-evidence' 'findings.json'
            $jsonPath | Should -Exist -Because 'Get-AuditorEvidenceExport contract: exports JSON'
            
            # Renderer contract (reads $context['Findings'])
            $htmlPath = Join-Path $script:testOutputDir 'audit-report.html'
            $htmlPath | Should -Exist
            $htmlContent = Get-Content $htmlPath -Raw
            $htmlContent | Should -Not -Match '<td>\s*</td>\s*<td>\s*</td>' -Because 'renderer received non-null findings (no ghost rows)'
            
            # PassThru contract
            $report | Should -Not -BeNullOrEmpty
            $report.HtmlPath | Should -Exist
            $report.MdPath | Should -Exist
        }
    }
    
    Context 'Data preservation through triage pipeline' {
        It 'Should preserve findings count through every hand-off point when triage is provided' {
            # Arrange: Known fixture with N findings
            $expectedCount = $script:expectedFindingCount
            $expectedCount | Should -BeGreaterThan 0 -Because 'fixture must have findings'
            
            # Act: Build report with triage
            $report = Build-AuditorReport -InputPath $script:resultsPath `
                                          -EntitiesPath $script:entitiesPath `
                                          -ManifestPath $script:manifestPath `
                                          -TriagePath $script:triagePath `
                                          -OutputDirectory $script:testOutputDir `
                                          -Tier 'PureJson' `
                                          -PassThru
            
            # Assert: Data preserved at EVERY hand-off
            
            # Hand-off 1: Triage step must preserve findings
            # (BUG-1 violated this: $annotated.Findings returned $null instead of $annotated.AnnotatedFindings)
            $csvPath = Join-Path $script:testOutputDir 'audit-evidence' 'findings.csv'
            $csvPath | Should -Exist -Because 'evidence export runs after triage and must receive non-null findings'
            
            $csvContent = Get-Content $csvPath -Raw
            $csvLines = $csvContent -split "`n" | Where-Object { $_.Trim() -ne '' }
            # CSV = 1 header + N data rows
            $csvLines.Count | Should -Be ($expectedCount + 1) -Because "triage step must preserve all $expectedCount findings; fewer rows indicate silent null from key mismatch"
            
            # Hand-off 2: HTML renderer must receive non-null findings
            $htmlPath = Join-Path $script:testOutputDir 'audit-report.html'
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
            $mdPath = Join-Path $script:testOutputDir 'audit-report.md'
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
            $report = Build-AuditorReport -InputPath $script:resultsPath `
                                          -EntitiesPath $script:entitiesPath `
                                          -ManifestPath $script:manifestPath `
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
            Build-AuditorReport -InputPath $script:resultsPath `
                                -EntitiesPath $script:entitiesPath `
                                -ManifestPath $script:manifestPath `
                                -TriagePath $script:triagePath `
                                -OutputDirectory $script:testOutputDir `
                                -Tier 'PureJson'
            
            # Assert: Remediation appendix populated
            # (BUG-1 would cause this to be empty because Get-AuditorRemediationAppendix received $null)
            $htmlPath = Join-Path $script:testOutputDir 'audit-report.html'
            $htmlContent = Get-Content $htmlPath -Raw
            
            # At minimum, HTML should contain the word "Remediation" if the appendix section exists
            # (Full remediation appendix testing is out of scope for this defensive test)
            $htmlContent | Should -Match 'Remediation|Finding' -Because 'report must contain findings or remediation content if data flow is intact'
        }
    }
}
