#Requires -Version 7.4

Describe 'New HTML report redesign contract (#295)' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:ManifestPath = Join-Path $RootDir 'tools' 'tool-manifest.json'
    }

    It 'renders one coverage tile per registered tool and required findings columns' {
        $tmp = Join-Path $TestDrive 'report-contract-tiles'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @(
            [pscustomobject]@{ Id='F-1'; Source='azqr'; Severity='High'; Compliant=$false; Title='AZQR.001: t'; RuleId='AZQR.001'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'; Frameworks=@('CIS Azure'); Category='Security' }
            [pscustomobject]@{ Id='F-2'; Source='trivy'; Severity='Medium'; Compliant=$false; Title='TRV.001: t'; RuleId='TRV.001'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'; Frameworks=@('NIST 800-53'); Category='Supply chain' }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw

        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        $expectedTools = @($manifest.tools).Count
        ([regex]::Matches($html, "<div class='tool ")).Count | Should -Be $expectedTools

        $html | Should -Match "<th data-sort='severity'"
        $html | Should -Match "<th data-sort='rule'"
        $html | Should -Match "<th data-sort='entity'"
        $html | Should -Match "<th data-sort='sub'"
        $html | Should -Match "<th data-sort='tool'"
        $html | Should -Match "<th data-sort='status'"
    }

    It 'handles empty results, supports entities envelope, and avoids CDN URLs' {
        $tmp = Join-Path $TestDrive 'report-contract-empty'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        '[]' | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        @{
            SchemaVersion = '3.1'
            Entities = @(@{ EntityId='sub-1'; EntityType='Subscription'; EntityName='sub-1' })
            Edges = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'entities.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        { & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null } | Should -Not -Throw
        $html = Get-Content $out -Raw

        $html | Should -Match 'No risk items in this run'
        $html | Should -Match 'Inventory by type'
        $html | Should -Match 'Tool × Severity'

        $urls = [regex]::Matches($html, 'https?://[^"''\s)]+') | ForEach-Object { $_.Value }
        $disallowed = @($urls | Where-Object { $_ -notmatch 'github\.com|README\.md|learn\.microsoft\.com|example\.com|portal\.azure\.com' })
        $disallowed.Count | Should -Be 0
    }

    It 'includes sticky sub-navigation anchors in the expected order' {
        $tmp = Join-Path $TestDrive 'report-contract-nav'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        '[]' | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw
        $html | Should -Match "href='#overview'"
        $html | Should -Match "href='#coverage'"
        $html | Should -Match "href='#heatmap'"
        $html | Should -Match "href='#risks'"
        $html | Should -Match "href='#findings'"
        $html | Should -Match "href='#entities'"
    }

    It 'renders header severity strip classes using design tokens' {
        $tmp = Join-Path $TestDrive 'report-contract-header'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        '[]' | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw
        $html | Should -Match '--crit:#7f1d1d'
        $html | Should -Match '--high:#b91c1c'
        $html | Should -Match '--med:#b45309'
        $html | Should -Match '--low:#a16207'
        $html | Should -Match '--info:#475569'
        $html | Should -Match '--pass:#15803d'
    }

    It 'contains findings table client functions for filter sort expand and csv' {
        $tmp = Join-Path $TestDrive 'report-contract-js'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        '[]' | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw
        $html | Should -Match 'applyFilters\('
        $html | Should -Match 'sortRows\('
        $html | Should -Match 'focusRisk'
        $html | Should -Match 'exportCsv'
    }

    It 'renders framework badges when Frameworks field is present' {
        $tmp = Join-Path $TestDrive 'report-contract-frameworks'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        @([pscustomobject]@{
            Id='F-1'; Source='azqr'; Severity='High'; Compliant=$false; Title='R1: t'; RuleId='R1'
            Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            Frameworks=@('CIS Azure','NIST 800-53')
        }) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw
        $html | Should -Match 'fw-cis'
        $html | Should -Match 'fw-nist'
    }

    It 'renders tool x severity fallback mode text when no subscriptions are present' {
        $tmp = Join-Path $TestDrive 'report-contract-fallback'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        @([pscustomobject]@{
            Id='F-1'; Source='trivy'; Severity='High'; Compliant=$false; Title='R1: t'; RuleId='R1'
            Detail='d'; Remediation='r'; EntityId='repo:owner/name'
        }) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw
        $html | Should -Match 'Tool × Severity'
        $html | Should -Match '"toolsev"'
    }

    It 'skips null remediation snippets and renders schema 2.2 before/after snippets' {
        $tmp = Join-Path $TestDrive 'report-contract-remediation-snippets'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        @(
            [pscustomobject]@{
                Id='F-1'; Source='zizmor'; Severity='High'; Compliant=$false; Title='template-injection'; RuleId='template-injection'
                Detail='d'; Remediation='r'; EntityId='octo/repo/.github/workflows/ci.yml'
                RemediationSnippets=@(
                    $null,
                    [pscustomobject]@{
                        language='yaml'
                        before='uses: actions/checkout@v4'
                        after='uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6'
                    }
                )
            }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        $out = Join-Path $tmp 'report.html'
        { & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null } | Should -Not -Throw
        $html = Get-Content $out -Raw
        $html | Should -Match '<details'
        $html | Should -Match 'Before:'
        $html | Should -Match 'After:'
    }
}
