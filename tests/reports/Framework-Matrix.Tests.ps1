#Requires -Version 7.4

Describe 'HTML report heatmap modes' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders heatmap toggle buttons including Tool x Severity fallback mode' {
        $tmp = Join-Path $TestDrive 'heatmap-modes'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        '[]' | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw

        $html | Should -Match 'Control domain × Subscription'
        $html | Should -Match 'Tool × Severity'
        $html | Should -Match 'Framework × Subscription'
        $html | Should -Match "hmMode=hmModel\.defaultMode\|\|'domain'"
    }

    It 'embeds heatmap model JSON for client rendering' {
        $tmp = Join-Path $TestDrive 'heatmap-model'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @([pscustomobject]@{
            Id='F-1'; Source='azqr'; Severity='High'; Compliant=$false; Title='R1: test'
            Detail='d'; Remediation='r'
            ResourceId='/subscriptions/sub-01/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa1'
            Frameworks=@('CIS Azure'); Category='Security'
        }) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw

        $html | Should -Match "<script type='application/json' id='hmModel'>"
        $html | Should -Match '"defaultMode"'
        $html | Should -Match '"matrices"'
    }
}
