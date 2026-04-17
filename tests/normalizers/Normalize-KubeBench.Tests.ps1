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

    It 'attaches kube-bench ControlId values' {
        $rows = @(Normalize-KubeBench -ToolResult $script:Fixture)
        $ids = @($rows | ForEach-Object { $_.ControlId })
        $ids | Should -Contain '4.2.6'
        $ids | Should -Contain '4.2.7'
    }
}
