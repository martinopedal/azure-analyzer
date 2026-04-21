#Requires -Version 7.4

Describe 'HTML report severity header strip' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders five severity counters in sticky header' {
        $tmp = Join-Path $TestDrive 'severity-header'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        @(
            [pscustomobject]@{ Id='F-1'; Source='azqr'; Severity='Critical'; Compliant=$false; Title='R1'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' }
            [pscustomobject]@{ Id='F-2'; Source='azqr'; Severity='High'; Compliant=$false; Title='R2'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2' }
            [pscustomobject]@{ Id='F-3'; Source='azqr'; Severity='Medium'; Compliant=$false; Title='R3'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm3' }
            [pscustomobject]@{ Id='F-4'; Source='azqr'; Severity='Low'; Compliant=$false; Title='R4'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm4' }
            [pscustomobject]@{ Id='F-5'; Source='azqr'; Severity='Info'; Compliant=$false; Title='R5'; Detail='d'; Remediation='r'; ResourceId='/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm5' }
        ) | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $tmp 'results.json') -Encoding UTF8

        $out = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath (Join-Path $tmp 'results.json') -OutputPath $out | Out-Null
        $html = Get-Content $out -Raw

        $html | Should -Match "aria-label='Findings by severity'"
        $html | Should -Match 'sev-cnt sev-crit'
        $html | Should -Match 'sev-cnt sev-high'
        $html | Should -Match 'sev-cnt sev-med'
        $html | Should -Match 'sev-cnt sev-low'
        $html | Should -Match 'sev-cnt sev-info'
    }
}
