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

    It 'renders a Resources tab and embeds model.entities when entities.json is present (issue #209)' {
        $tmp = Join-Path $TestDrive 'html-resources'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8

        # v3.1 envelope shape with one entity carrying one observation
        $entitiesPath = Join-Path $tmp 'entities.json'
        @{
            SchemaVersion = '3.1'
            Entities = @(
                @{
                    EntityId          = 'sub-1/rg-1/vm-1'
                    EntityName        = 'vm-prod-01'
                    EntityType        = 'Microsoft.Compute/virtualMachines'
                    Platform          = 'Azure'
                    ResourceGroup     = 'rg-1'
                    WorstSeverity     = 'High'
                    NonCompliantCount = 2
                    CompliantCount    = 1
                    Sources           = @('azqr','psrule')
                    MonthlyCost       = 42.50
                    Observations      = @(
                        @{ Severity = 'High'; Detail = 'Public IP exposed'; Remediation = 'Move behind a load balancer'; DocsUrl = 'https://learn.microsoft.com/azure/security' },
                        @{ Severity = 'Low'; Detail = 'Tag missing: owner'; Remediation = 'Add owner tag' }
                    )
                }
            )
            Edges = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $entitiesPath -Encoding UTF8

        $outputPath = Join-Path $tmp 'report.html'

        {
            & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        } | Should -Not -Throw

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw

        # Resources section marker
        $html | Should -Match '<h2 id="resources">Resources</h2>'
        $html | Should -Match 'id="resources-table"'
        # Entity row rendered
        $html | Should -Match 'vm-prod-01'
        $html | Should -Match 'rg-1'
        # Worst severity badge with color class
        $html | Should -Match 'class="badge sev-high"'
        # Observations sub-table present
        $html | Should -Match 'observations-table'
        $html | Should -Match 'Public IP exposed'
        # Embedded JSON model contains entities
        $html | Should -Match 'id="report-model"'
        $html | Should -Match '"entities"'
        # toggle JS function injected
        $html | Should -Match 'function toggleEntityDetail'
    }

    It 'gracefully degrades when entities.json is missing (issue #209)' {
        $tmp = Join-Path $TestDrive 'html-no-entities'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        {
            & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        } | Should -Not -Throw

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw
        # Empty model is still embedded for client compatibility
        $html | Should -Match 'id="report-model"'
        $html | Should -Match '"entities":\[\]'
        # No Resources section emitted server-side when there are no entities
        $html | Should -Not -Match '<h2 id="resources">'
    }
}
