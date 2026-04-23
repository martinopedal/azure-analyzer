#Requires -Version 7.4

Describe 'HTML report findings table interactions' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        
        # Pre-generate the report once for all tests to avoid repeated HTML generation
        $script:TmpDir = Join-Path $TestDrive 'findings-rows'
        $null = New-Item -ItemType Directory -Path $script:TmpDir -Force

        @(
            [pscustomobject]@{ Id='F-1'; Source='azqr'; Severity='High'; Compliant=$false; Title='R1: test'; RuleId='R1'; Detail='detail'; Remediation='rem'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' }
            [pscustomobject]@{ Id='F-2'; Source='psrule'; Severity='Low'; Compliant=$false; Title='R2: test'; RuleId='R2'; Detail='detail2'; Remediation='rem2'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2' }
        ) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $script:TmpDir 'results.json') -Encoding UTF8

        $script:ReportPath = Join-Path $script:TmpDir 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $script:TmpDir 'results.json') -OutputPath $script:ReportPath | Out-Null
        $script:Html = Get-Content $script:ReportPath -Raw
    }

    It 'server-renders findings rows and hidden expand rows for client toggling' {
        $script:Html | Should -Match "<tbody id='fndBody'>"
        ([regex]::Matches($script:Html, "<tr class='row s-")).Count | Should -Be 2
        ([regex]::Matches($script:Html, "<tr class='expand' data-parent-id='")).Count | Should -Be 2
        $script:Html | Should -Match 'Export CSV'
        $script:Html | Should -Match 'focusRisk'
    }
}
