#Requires -Version 7.4

Describe 'HTML report collapsible findings tree' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders tool-category-rule hierarchy with expected count badges and tree controls' {
        $tmp = Join-Path $TestDrive 'collapsible-tree'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $findings = @(
            [pscustomobject]@{ Id='F-01'; Source='azqr';  Category='Security';  Title='AZR-001: NSG open to internet'; Severity='High';     Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-a/providers/Microsoft.Network/networkSecurityGroups/nsg1'; LearnMoreUrl='https://example.com/fix-1'; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-02'; Source='azqr';  Category='Security';  Title='AZR-001: NSG open to internet (vm2)'; Severity='Critical'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-a/providers/Microsoft.Network/networkSecurityGroups/nsg2'; LearnMoreUrl='https://example.com/fix-2'; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-03'; Source='azqr';  Category='Cost';      Title='CST-010: Idle disk'; Severity='Low'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-b/providers/Microsoft.Compute/disks/d1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-04'; Source='trivy'; Category='Security';  Title='TRVY-100: vulnerable package'; Severity='Medium'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-c/providers/Microsoft.Web/sites/app1'; LearnMoreUrl=''; Platform='GitHub'; Controls=@(); Frameworks=@() }
        )

        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 6 | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null

        $html = Get-Content $outputPath -Raw

        $html | Should -Match 'id="findings-tree"'
        $html | Should -Match 'class="tree-node tree-node-tool"'
        $html | Should -Match 'class="tree-node tree-node-category"'
        $html | Should -Match 'class="tree-node tree-node-rule"'
        $html | Should -Match 'data-tree-finding="true"'
        $html | Should -Match 'Fix it</a>'

        # Tool and hierarchy counts
        $html | Should -Match 'azqr</span> <span class="tree-count">\(2 categories\)</span>'
        $html | Should -Match 'trivy</span> <span class="tree-count">\(1 categories\)</span>'
        $html | Should -Match 'Security</span> <span class="tree-count">\(1 rules\)</span>'
        $html | Should -Match 'AZR-001</span> <span class="tree-count">\(2 findings\)</span>'

        # All five severity dots rendered at node level
        $html | Should -Match 'tree-dot-critical'
        $html | Should -Match 'tree-dot-high'
        $html | Should -Match 'tree-dot-medium'
        $html | Should -Match 'tree-dot-low'
        $html | Should -Match 'tree-dot-info'

        # Expand/collapse controls and persisted state helpers
        $html | Should -Match 'setTreeExpansion\(true\)'
        $html | Should -Match 'setTreeExpansion\(false\)'
        $html | Should -Match 'localStorage\.setItem'
        $html | Should -Match 'azure-analyzer:findings-tree:'

        # Severity-strip and global filter integration hooks
        $html | Should -Match 'filterBySeverityStrip'
        $html | Should -Match 'syncFindingsTreeVisibility'
        $html | Should -Match 'treeHasActiveFilter'
    }

    It 'uses the RuleId field as the level-3 grouping key when supplied (v2.1)' {
        $tmp = Join-Path $TestDrive 'collapsible-tree-ruleid'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        # Two findings with the same explicit RuleId but unrelated titles must
        # still collapse into a single level-3 rule node. RuleId wins over the
        # heuristic title prefix derivation from PR #275.
        $findings = @(
            [pscustomobject]@{ Id='F-RID-1'; Source='psrule'; Category='Security'; Title='Storage account allows HTTP'; RuleId='Azure.Storage.SecureTransfer'; Severity='High';   Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-a/providers/Microsoft.Storage/storageAccounts/st1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-RID-2'; Source='psrule'; Category='Security'; Title='HTTPS not enforced on stprodlogs'; RuleId='Azure.Storage.SecureTransfer'; Severity='High';   Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg-a/providers/Microsoft.Storage/storageAccounts/st2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
        )

        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 6 | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null

        $html = Get-Content $outputPath -Raw

        # Both findings collapse into one level-3 rule node keyed by the supplied RuleId.
        $html | Should -Match 'Azure\.Storage\.SecureTransfer</span> <span class="tree-count">\(2 findings\)</span>'
    }
}
