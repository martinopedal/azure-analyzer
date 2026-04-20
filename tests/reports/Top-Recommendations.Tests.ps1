#Requires -Version 7.4

Describe 'HTML report top recommendations by impact' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders top recommendations ordered by impact score' {
        $tmp = Join-Path $TestDrive 'top-recs-order'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $findings = @(
            [pscustomobject]@{ Id='F-H-1'; Source='azqr'; Category='Security'; Title='HIGH-001: h1'; RuleId='HIGH-001'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv1'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv1'; LearnMoreUrl='https://example.com/high'; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-H-2'; Source='azqr'; Category='Security'; Title='HIGH-001: h2'; RuleId='HIGH-001'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv2'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-H-3'; Source='azqr'; Category='Security'; Title='HIGH-001: h3'; RuleId='HIGH-001'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv3'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv3'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-H-4'; Source='azqr'; Category='Security'; Title='HIGH-001: h4'; RuleId='HIGH-001'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv3'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv3'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-C-1'; Source='psrule'; Category='Security'; Title='CRIT-001: c1'; RuleId='CRIT-001'; Severity='Critical'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st1'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st1'; LearnMoreUrl='https://example.com/critical'; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-C-2'; Source='psrule'; Category='Security'; Title='CRIT-001: c2'; RuleId='CRIT-001'; Severity='Critical'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st2'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
        )

        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $html = Get-Content $outputPath -Raw

        $html | Should -Match 'id="top-recommendations-title"'
        $html | Should -Match "data-rule-key='HIGH-001'"
        $html | Should -Match "data-rule-key='CRIT-001'"
        $html | Should -Match 'Impact score:\s*<strong>60</strong>'
        $html | Should -Match 'Impact score:\s*<strong>40</strong>'

        $highPos = $html.IndexOf("data-rule-key='HIGH-001'")
        $critPos = $html.IndexOf("data-rule-key='CRIT-001'")
        $highPos | Should -BeLessThan $critPos
    }

    It 'respects -TopRecommendationsCount' {
        $tmp = Join-Path $TestDrive 'top-recs-count'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $findings = @(
            [pscustomobject]@{ Id='F-1'; Source='azqr'; Category='Security'; Title='R1 issue'; RuleId='R1'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='entity:r1'; ResourceId='entity:r1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-2'; Source='azqr'; Category='Security'; Title='R2 issue'; RuleId='R2'; Severity='Medium'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='entity:r2'; ResourceId='entity:r2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-3'; Source='azqr'; Category='Security'; Title='R3 issue'; RuleId='R3'; Severity='Low'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='entity:r3'; ResourceId='entity:r3'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
        )

        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath -TopRecommendationsCount 2 | Out-Null
        $html = Get-Content $outputPath -Raw

        ([regex]::Matches($html, "class='top-rec-card'")).Count | Should -Be 2
    }

    It 'uses RuleId as primary key and title-prefix fallback when RuleId is empty' {
        $tmp = Join-Path $TestDrive 'top-recs-fallback'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $findings = @(
            [pscustomobject]@{ Id='F-RID-1'; Source='psrule'; Category='Security'; Title='Unrelated title one'; RuleId='Azure.Storage.SecureTransfer'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='entity:rid1'; ResourceId='entity:rid1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-RID-2'; Source='psrule'; Category='Security'; Title='Another title two'; RuleId='Azure.Storage.SecureTransfer'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='entity:rid2'; ResourceId='entity:rid2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-FB-1'; Source='azqr'; Category='Security'; Title='AZR-123: open endpoint'; RuleId=''; Severity='Low'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='entity:fb1'; ResourceId='entity:fb1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-FB-2'; Source='azqr'; Category='Security'; Title='AZR-123: open endpoint on second resource'; RuleId=''; Severity='Low'; Compliant=$false; Detail='d'; Remediation='r'; EntityId='entity:fb2'; ResourceId='entity:fb2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
        )

        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $html = Get-Content $outputPath -Raw

        $html | Should -Match "data-rule-key='Azure\.Storage\.SecureTransfer'"
        $html | Should -Match "data-rule-key='AZR-123'"
        $html | Should -Match "data-rule-key=""Azure\.Storage\.SecureTransfer"""
        $html | Should -Match "data-rule-key=""AZR-123"""
    }
}
