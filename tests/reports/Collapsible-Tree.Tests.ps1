#Requires -Version 7.4

Describe 'HTML report findings table interactions' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'server-renders findings rows and hidden expand rows for client toggling' {
        $tmp = Join-Path $TestDrive 'findings-rows'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @(
            [pscustomobject]@{ Id='F-1'; Source='azqr'; Severity='High'; Compliant=$false; Title='R1: test'; RuleId='R1'; Detail='detail'; Remediation='rem'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' }
            [pscustomobject]@{ Id='F-2'; Source='psrule'; Severity='Low'; Compliant=$false; Title='R2: test'; RuleId='R2'; Detail='detail2'; Remediation='rem2'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2' }
        ) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw

        $html | Should -Match "<tbody id='fndBody'>"
        ([regex]::Matches($html, "<tr class='row s-")).Count | Should -Be 2
        ([regex]::Matches($html, "<tr class='expand' data-parent-id='")).Count | Should -Be 2
        $html | Should -Match 'Export CSV'
        $html | Should -Match 'focusRisk'
    }
}
