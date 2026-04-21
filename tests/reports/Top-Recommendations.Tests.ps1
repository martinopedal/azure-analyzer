#Requires -Version 7.4

Describe 'HTML report top recommendations and top risks' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'caps Top risks panel at 10 rows and anchors to findings section' {
        $tmp = Join-Path $TestDrive 'top-risks-cap'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $rows = for ($i = 1; $i -le 15; $i++) {
            [pscustomobject]@{
                Id = "F-$i"; Source = 'azqr'; Severity = 'High'; Compliant = $false
                Title = "RULE-${i}: item"; RuleId = "RULE-$i"; Detail = 'd'; Remediation = 'r'
                ResourceId = "/subscriptions/sub-01/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv$i"
                Frameworks = @('CIS Azure')
            }
        }

        $rows | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8
        $out = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw

        ([regex]::Matches($html, "<div class='risk'>")).Count | Should -Be 10
        $html | Should -Match "onclick='focusRisk\("
        $html | Should -Match "href='#findings'"
    }

    It 'respects -TopRecommendationsCount for overview recommendation list' {
        $tmp = Join-Path $TestDrive 'top-recs-limit'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @(
            [pscustomobject]@{ Id='F-1'; Source='azqr'; Severity='High'; Compliant=$false; Title='R1: one'; RuleId='R1'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' }
            [pscustomobject]@{ Id='F-2'; Source='azqr'; Severity='Medium'; Compliant=$false; Title='R2: two'; RuleId='R2'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2' }
            [pscustomobject]@{ Id='F-3'; Source='azqr'; Severity='Low'; Compliant=$false; Title='R3: three'; RuleId='R3'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm3' }
        ) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out -TopRecommendationsCount 2 | Out-Null
        $html = Get-Content $out -Raw

        ([regex]::Matches($html, "<div class='rec'>")).Count | Should -Be 2
    }
}
