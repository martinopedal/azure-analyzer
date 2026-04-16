Describe 'Normalize-Kubescape' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-Kubescape.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'kubescape-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when Status is not Success' {
        $r = @(Normalize-Kubescape -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $r.Count | Should -Be 0
    }

    It 'emits one FindingRow per non-passing control' {
        $rows = @(Normalize-Kubescape -ToolResult $script:Fixture)
        $rows.Count | Should -Be 2
    }

    It 'every row maps to AzureResource entity on the AKS cluster ARM ID' {
        $rows = @(Normalize-Kubescape -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityType | Should -Be 'AzureResource'
            $r.Source     | Should -Be 'kubescape'
            $r.Platform   | Should -Be 'Azure'
            $r.Category   | Should -Be 'KubernetesPosture'
            $r.Compliant  | Should -BeFalse
            $r.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $r.ResourceGroup  | Should -Be 'prod'
        }
    }

    It 'preserves kubescape severity (High / Medium)' {
        $rows = @(Normalize-Kubescape -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.Severity -eq 'High' }).Count   | Should -Be 1
        ($rows | Where-Object { $_.Severity -eq 'Medium' }).Count | Should -Be 1
    }

    It 'attaches ControlId for framework mapping' {
        $rows = @(Normalize-Kubescape -ToolResult $script:Fixture)
        $ids = @($rows | ForEach-Object { $_.ControlId })
        $ids | Should -Contain 'C-0017'
        $ids | Should -Contain 'C-0038'
    }
}
