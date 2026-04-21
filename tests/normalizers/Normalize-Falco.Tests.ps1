Describe 'Normalize-Falco' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-Falco.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'falco' 'falco-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when Status is not Success' {
        $r = @(Normalize-Falco -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $r.Count | Should -Be 0
    }

    It 'emits one FindingRow per Falco alert' {
        $rows = @(Normalize-Falco -ToolResult $script:Fixture)
        $rows.Count | Should -Be 4
    }

    It 'maps each row to AKS AzureResource entity and expected category' {
        $rows = @(Normalize-Falco -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityType      | Should -Be 'AzureResource'
            $r.Source          | Should -Be 'falco'
            $r.Platform        | Should -Be 'Azure'
            $r.Category        | Should -Be 'KubernetesRuntimeThreatDetection'
            $r.Compliant       | Should -BeFalse
            $r.SubscriptionId  | Should -Be '11111111-1111-1111-1111-111111111111'
            $r.ResourceGroup   | Should -Be 'prod'
        }
    }

    It 'maps Falco priority to severity (Critical/Error/Warning/Notice)' {
        $rows = @(Normalize-Falco -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.Severity -eq 'Critical' }).Count | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'High' }).Count     | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'Medium' }).Count   | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'Low' }).Count      | Should -Be 1
    }

    It 'preserves RuleName/Pod/Process metadata' {
        $rows = @(Normalize-Falco -ToolResult $script:Fixture)
        $rules = @($rows | ForEach-Object { $_.RuleName })
        $pods  = @($rows | ForEach-Object { $_.Pod })
        $procs = @($rows | ForEach-Object { $_.Process })
        $rules | Should -Contain 'Terminal shell in container'
        $pods  | Should -Contain 'payment-api-7bb4f4'
        $procs | Should -Contain 'bash'
    }

    It 'maps Schema 2.2 security metadata for runtime threat findings' {
        $rows = @(Normalize-Falco -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.SchemaVersion | Should -Be '2.2'
            $r.RuleId | Should -Match '^falco:'
            $r.Pillar | Should -Be 'Security'
            $r.Impact | Should -BeIn @('High', 'Medium', 'Low')
            $r.Effort | Should -BeIn @('Medium', 'Low')
            $r.DeepLinkUrl | Should -Match '^https://'
            @($r.RemediationSnippets).Count | Should -BeGreaterThan 0
            @($r.EvidenceUris).Count | Should -BeGreaterThan 0
            @($r.BaselineTags).Count | Should -BeGreaterThan 2
            @($r.Frameworks).Count | Should -BeGreaterThan 0
            @($r.MitreTactics).Count | Should -BeGreaterThan 0
            @($r.MitreTechniques).Count | Should -BeGreaterThan 0
            $r.EntityRefs | Should -Contain $r.EntityId
            $r.ToolVersion | Should -Not -BeNullOrEmpty
        }
        $shellFinding = $rows | Where-Object { $_.RuleName -eq 'Terminal shell in container' } | Select-Object -First 1
        $shellFinding.Frameworks[0].Name | Should -Be 'CIS Kubernetes Benchmark'
        $shellFinding.MitreTechniques | Should -Contain 'T1059'
    }
}
