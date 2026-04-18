#Requires -Version 7.4

Describe 'New-HtmlReport' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders a valid HTML shell with an empty portfolio state for empty management-group scans' {
        $tmp = Join-Path $TestDrive 'html-empty-portfolio'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8

        $portfolioPath = Join-Path $tmp 'portfolio.json'
        @{
            SchemaVersion = '1.0'
            Summary       = @{
                ManagementGroupId = 'platform-connectivity'
                SubscriptionCount = 0
                TotalFindings     = 0
            }
            Subscriptions = @()
            ManagementGroups = @()
            Correlations  = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $portfolioPath -Encoding UTF8

        $outputPath = Join-Path $tmp 'report.html'

        {
            & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        } | Should -Not -Throw

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match '<html lang="en">'
        $html | Should -Match 'Portfolio rollup'
        $html | Should -Match 'No findings in portfolio\.'
        $html | Should -Match 'platform-connectivity'
    }
}
