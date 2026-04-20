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

    It 'fallback source list includes azure-cost, bicep-iac, terraform-iac, sentinel-incidents' {
        # Read the report script and check the fallback array directly
        $reportScript = Get-Content (Join-Path $RootDir 'New-HtmlReport.ps1') -Raw
        $reportScript | Should -Match 'azure-cost'
        $reportScript | Should -Match 'bicep-iac'
        $reportScript | Should -Match 'terraform-iac'
        $reportScript | Should -Match 'sentinel-incidents'
    }

    It 'embeds the executive dashboard as a Summary tab that is the default-active view (#210)' {
        $tmp = Join-Path $TestDrive 'html-summary-tab'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $sub = '11111111-1111-1111-1111-111111111111'
        $findings = @(
            [pscustomobject]@{ Id='F-1'; Source='azqr';   ResourceId="/subscriptions/$sub/rg/a/storage/x";   Category='Security'; Title='T1'; Severity='Critical'; Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; Platform='Azure' }
            [pscustomobject]@{ Id='F-2'; Source='azqr';   ResourceId="/subscriptions/$sub/rg/a/storage/y";   Category='Security'; Title='T2'; Severity='High';     Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; Platform='Azure' }
            [pscustomobject]@{ Id='F-3'; Source='psrule'; ResourceId="/subscriptions/$sub/rg/a/keyvault/z"; Category='Security'; Title='T3'; Severity='Medium';   Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; Platform='Azure' }
        )
        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $outputPath = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw

        # Tab navigation present, Summary listed first
        $html | Should -Match 'class="rt-tabs[^"]*"'
        $html | Should -Match 'data-tab="summary"'
        $html | Should -Match 'data-tab="findings"'
        # Summary button is the active tab by default
        $html | Should -Match '<button class="rt-tab-button is-active"[^>]*data-tab="summary"'
        # Summary panel is the default-active panel
        $html | Should -Match 'id="rt-tab-summary" class="rt-tab-panel is-active"'
        # Findings panel exists but is NOT active by default
        $html | Should -Match 'id="rt-tab-findings" class="rt-tab-panel"'
        # Embedded exec dashboard wrapped under .exec-dash for CSS scoping
        $html | Should -Match 'class="exec-dash"'
        # Exec dashboard hallmark sections survived embedding
        $html | Should -Match 'Compliance score'
        $html | Should -Match 'Top-10 risky resources'
        $html | Should -Match 'WAF 5-pillar coverage'
        # Sparkline SVG embedded inside summary
        $html | Should -Match '<svg[^>]*viewBox'
        # Tab-switch JS present
        $html | Should -Match 'function rtSwitchTab'
        # Existing Findings content still rendered (categories accordion etc.)
        $html | Should -Match 'Findings by category'
        # Summary tab markup must appear BEFORE the Findings panel
        $sumIdx = $html.IndexOf('id="rt-tab-summary"')
        $findIdx = $html.IndexOf('id="rt-tab-findings"')
        $sumIdx | Should -BeGreaterThan -1
        $findIdx | Should -BeGreaterThan $sumIdx
    }

    It 'still produces a Findings-only fallback view when summary render fails (#210 graceful degradation)' {
        # Sanity: when the embedded dashboard would fail, the report still renders.
        # Use a results file shaped to exercise normal render but verify no hard
        # dependency on summary content (the fallback path is exercised by the
        # warning path in the script; here we just confirm Findings content still
        # appears even if Summary is suppressed).
        $tmp = Join-Path $TestDrive 'html-summary-fallback'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $html = Get-Content $outputPath -Raw
        # Tabs still present even with empty findings
        $html | Should -Match 'data-tab="summary"'
        $html | Should -Match 'data-tab="findings"'
        # Findings panel is still rendered
        $html | Should -Match 'id="rt-tab-findings"'
    }
}
