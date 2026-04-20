#Requires -Version 7.4

Describe 'HTML report severity strip' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders a findings-tree severity strip with all five levels and total' {
        $tmp = Join-Path $TestDrive 'severity-strip-tree'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $findings = @(
            [pscustomobject]@{ Id='F-01'; Source='azqr'; Category='Security'; Title='Critical finding'; Severity='Critical'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vm1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-02'; Source='azqr'; Category='Security'; Title='High finding 1'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-a/providers/Microsoft.Network/networkSecurityGroups/nsg1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-03'; Source='psrule'; Category='Security'; Title='High finding 2'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-a/providers/Microsoft.KeyVault/vaults/kv1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-04'; Source='psrule'; Category='Identity'; Title='Medium finding 1'; Severity='Medium'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-b/providers/Microsoft.Storage/storageAccounts/st1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-05'; Source='psrule'; Category='Identity'; Title='Medium finding 2'; Severity='Medium'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-b/providers/Microsoft.Storage/storageAccounts/st2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-06'; Source='trivy'; Category='Identity'; Title='Low finding 1'; Severity='Low'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-c/providers/Microsoft.Web/sites/app1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-07'; Source='maester'; Category='Operations'; Title='Info finding 1'; Severity='Info'; Compliant=$true; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-d/providers/Microsoft.Resources/tags/tag1'; LearnMoreUrl=''; Platform='Entra'; Controls=@(); Frameworks=@() }
        )

        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 6 | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null

        $html = Get-Content $outputPath -Raw

        $html | Should -Match 'aria-label="Severity totals for findings tree"'
        $html | Should -Match 'filterBySeverityStrip'
        $html | Should -Match 'Critical:\s*1'
        $html | Should -Match 'High:\s*2'
        $html | Should -Match 'Medium:\s*2'
        $html | Should -Match 'Low:\s*1'
        $html | Should -Match 'Info:\s*1'
        $html | Should -Match 'Total:\s*7'
    }
}
