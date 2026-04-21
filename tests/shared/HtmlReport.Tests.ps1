#Requires -Version 7.4

Describe 'New-HtmlReport' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders sample-aligned shell and core sections for empty results' {
        $tmp = Join-Path $TestDrive 'html-empty'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        '[]' | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        { & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null } | Should -Not -Throw

        $html = Get-Content $out -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match '<header class=''app'''
        $html | Should -Match '<section class=''section'' id=''overview''>'
        $html | Should -Match '<section class=''section'' id=''coverage''>'
        $html | Should -Match '<section class=''section'' id=''heatmap''>'
        $html | Should -Match '<section class=''section'' id=''risks''>'
        $html | Should -Match '<section class=''section'' id=''findings''>'
        $html | Should -Match '<section class=''section'' id=''entities''>'
        $html | Should -Match "localStorage\.setItem\('aa-theme'"
    }

    It 'renders Schema 2.2 fields conditionally when present' {
        $tmp = Join-Path $TestDrive 'html-schema22'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @(
            [pscustomobject]@{
                Id='F-1'; Source='azqr'; Severity='High'; Compliant=$false; Title='AZR-001: t'
                Detail='detail'; Remediation='remediation'
                ResourceId='/subscriptions/sub-01/resourceGroups/rg-01/providers/Microsoft.Storage/storageAccounts/sa1'
                Pillar='Security'; Frameworks=@('CIS Azure'); Impact='High'; Effort='Medium'
                DeepLinkUrl='https://portal.azure.com/#view/test'
                RemediationSnippets=@(@{ Name='CLI'; Snippet='az storage update' })
                EvidenceUris=@('https://example.com/evidence')
                MitreTactics=@('TA0001'); MitreTechniques=@('T1078')
            }
        ) | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw

        $html | Should -Match 'Impact and effort'
        $html | Should -Match 'Open deep link'
        $html | Should -Match 'Evidence link'
        $html | Should -Match 'MITRE'
        $html | Should -Match 'az storage update'
        $html | Should -Match 'CIS Azure'
    }
}
