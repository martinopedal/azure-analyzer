Describe 'Normalize-KubeBench' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-KubeBench.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'kube-bench-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when Status is not Success' {
        $r = @(Normalize-KubeBench -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $r.Count | Should -Be 0
    }

    It 'maps FAIL and WARN findings and ignores PASS' {
        $rows = @(Normalize-KubeBench -ToolResult $script:Fixture)
        $rows.Count | Should -Be 2
    }

    It 'maps rows to AKS AzureResource entity metadata' {
        $rows = @(Normalize-KubeBench -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityType | Should -Be 'AzureResource'
            $r.Source | Should -Be 'kube-bench'
            $r.Platform | Should -Be 'Azure'
            $r.Category | Should -Be 'KubernetesNodeSecurity'
            $r.Compliant | Should -BeFalse
            $r.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $r.ResourceGroup | Should -Be 'prod'
        }
    }

    It 'preserves severity mapping for FAIL/WARN findings' {
        $rows = @(Normalize-KubeBench -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.Severity -eq 'High' }).Count | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'Medium' }).Count | Should -Be 1
    }

    It 'maps control identity to RuleId and Controls' {
        $rows = @(Normalize-KubeBench -ToolResult $script:Fixture)
        $ruleIds = @($rows | ForEach-Object { $_.RuleId })
        $ruleIds | Should -Contain 'kube-bench:4.2.6'
        $ruleIds | Should -Contain 'kube-bench:4.2.7'
        ($rows | Where-Object { $_.RuleId -eq 'kube-bench:4.2.6' }).Controls | Should -Contain '4.2.6'
    }

    It 'propagates Schema 2.2 kube-bench metadata fields' {
        $rows = @(Normalize-KubeBench -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.SchemaVersion | Should -Be '2.2'
            $row.Pillar | Should -Be 'Security'
            $row.DeepLinkUrl | Should -Be 'https://github.com/aquasecurity/kube-bench'
            @($row.Frameworks).Count | Should -BeGreaterThan 1
            @($row.BaselineTags).Count | Should -BeGreaterThan 1
            @($row.RemediationSnippets).Count | Should -BeGreaterThan 0
            @($row.EntityRefs).Count | Should -BeGreaterThan 0
            $row.ToolVersion | Should -Be 'v0.7.2'
        }

        $fail = $rows | Where-Object { $_.RuleId -eq 'kube-bench:4.2.6' } | Select-Object -First 1
        $warn = $rows | Where-Object { $_.RuleId -eq 'kube-bench:4.2.7' } | Select-Object -First 1
        $fail.Impact | Should -Be 'High'
        $warn.Impact | Should -Be 'Medium'
        @($fail.Frameworks.kind) | Should -Contain 'CIS Kubernetes Benchmark'
        @($fail.Frameworks.kind) | Should -Contain 'CIS-AKS'
        $fail.BaselineTags | Should -Contain 'FAIL'
    }
}
