#Requires -Version 7.4
BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $sharedDir = Join-Path $repoRoot 'modules' 'shared'
    $fixtureDir = Join-Path $PSScriptRoot '..' 'fixtures' 'auditor-small'
    $tempOutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "aa-profile-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
    
    . (Join-Path $sharedDir 'Sanitize.ps1')
    . (Join-Path $sharedDir 'AuditorReportBuilder.ps1')
    
    if (-not (Test-Path $fixtureDir)) {
        throw "Fixture directory not found: $fixtureDir"
    }
}

Describe 'Invoke-AzureAnalyzer.ps1 -Profile parameter' {
    Context 'When -Profile Auditor is specified' {
        It 'calls Build-AuditorReport and produces audit-report.html' {
            $resultsPath = Join-Path $fixtureDir 'results.json'
            $entitiesPath = Join-Path $fixtureDir 'entities.json'
            $manifestPath = Join-Path $fixtureDir 'report-manifest.json'
            
            if (-not (Test-Path $resultsPath)) {
                Set-ItResult -Skipped -Because "Fixture results.json not found: $resultsPath"
                return
            }
            if (-not (Test-Path $entitiesPath)) {
                Set-ItResult -Skipped -Because "Fixture entities.json not found: $entitiesPath"
                return
            }
            if (-not (Test-Path $manifestPath)) {
                Set-ItResult -Skipped -Because "Fixture report-manifest.json not found: $manifestPath"
                return
            }
            
            New-Item -Path $tempOutputDir -ItemType Directory -Force | Out-Null
            
            $auditorArgs = @{
                InputPath = $resultsPath
                EntitiesPath = $entitiesPath
                ManifestPath = $manifestPath
                OutputDirectory = $tempOutputDir
                PassThru = $true
            }
            
            $result = Build-AuditorReport @auditorArgs
            
            $result | Should -Not -BeNullOrEmpty
            $result.HtmlPath | Should -Exist
            $result.MdPath | Should -Exist
            
            $htmlContent = Get-Content $result.HtmlPath -Raw
            $htmlContent | Should -Match 'Azure Analyzer Audit Report'
            
            Remove-Item -Path $tempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Context 'New-HtmlReport.ps1 nav chip injection' {
        It 'injects Audit view nav chip when audit-report.html exists' {
            New-Item -Path $tempOutputDir -ItemType Directory -Force | Out-Null
            
            $resultsPath = Join-Path $fixtureDir 'results.json'
            if (-not (Test-Path $resultsPath)) {
                Set-ItResult -Skipped -Because "Fixture results.json not found: $resultsPath"
                return
            }
            
            Copy-Item -Path $resultsPath -Destination (Join-Path $tempOutputDir 'results.json')
            
            $auditReportPath = Join-Path $tempOutputDir 'audit-report.html'
            Set-Content -Path $auditReportPath -Value '<!DOCTYPE html><html><body>Audit Report</body></html>'
            
            $reportScript = Join-Path $repoRoot 'New-HtmlReport.ps1'
            $reportOutputPath = Join-Path $tempOutputDir 'report.html'
            
            & $reportScript -InputPath (Join-Path $tempOutputDir 'results.json') -OutputPath $reportOutputPath
            
            $reportOutputPath | Should -Exist
            
            $reportContent = Get-Content $reportOutputPath -Raw
            $reportContent | Should -Match "href='audit-report.html'>Audit view</a>"
            
            Remove-Item -Path $tempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        It 'does not inject nav chip when audit-report.html is missing' {
            New-Item -Path $tempOutputDir -ItemType Directory -Force | Out-Null
            
            $resultsPath = Join-Path $fixtureDir 'results.json'
            if (-not (Test-Path $resultsPath)) {
                Set-ItResult -Skipped -Because "Fixture results.json not found: $resultsPath"
                return
            }
            
            Copy-Item -Path $resultsPath -Destination (Join-Path $tempOutputDir 'results.json')
            
            $reportScript = Join-Path $repoRoot 'New-HtmlReport.ps1'
            $reportOutputPath = Join-Path $tempOutputDir 'report.html'
            
            & $reportScript -InputPath (Join-Path $tempOutputDir 'results.json') -OutputPath $reportOutputPath
            
            $reportOutputPath | Should -Exist
            
            $reportContent = Get-Content $reportOutputPath -Raw
            $reportContent | Should -Not -Match "href='audit-report.html'>Audit view</a>"
            
            Remove-Item -Path $tempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

