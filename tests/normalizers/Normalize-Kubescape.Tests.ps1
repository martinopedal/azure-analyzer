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

    It 'maps control identity to RuleId and Controls' {
        $rows = @(Normalize-Kubescape -ToolResult $script:Fixture)
        $ruleIds = @($rows | ForEach-Object { $_.RuleId })
        $ruleIds | Should -Contain 'kubescape:C-0017'
        $ruleIds | Should -Contain 'kubescape:C-0038'
        ($rows | Where-Object { $_.RuleId -eq 'kubescape:C-0017' }).Controls | Should -Contain 'C-0017'
    }

    It 'propagates Schema 2.2 fields including multi-framework and MITRE data' {
        $rows = @(Normalize-Kubescape -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.SchemaVersion | Should -Be '2.2'
            $row.Pillar | Should -Be 'Security'
            $row.ToolVersion | Should -Match '^kubescape version'
            @($row.EvidenceUris).Count | Should -BeGreaterThan 0
            @($row.Frameworks).Count | Should -BeGreaterThan 1
            @($row.BaselineTags).Count | Should -BeGreaterThan 1
            @($row.MitreTactics).Count | Should -BeGreaterThan 0
            @($row.MitreTechniques).Count | Should -BeGreaterThan 0
        }

        $first = $rows | Where-Object { $_.RuleId -eq 'kubescape:C-0017' } | Select-Object -First 1
        @($first.Frameworks.Name) | Should -Contain 'NSA'
        @($first.Frameworks.Name) | Should -Contain 'CIS'
        @($first.Frameworks.Name) | Should -Contain 'MITRE ATT&CK'
        $first.EvidenceUris | Should -Contain 'https://hub.armosec.io/docs/c-0017'
    }

    It 'maps Info severity explicitly instead of falling to default' {
        $infoInput = [PSCustomObject]@{
            Status   = 'Success'
            Findings = @(
                [PSCustomObject]@{
                    Id         = [guid]::NewGuid().ToString()
                    ResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/prod/providers/Microsoft.ContainerService/managedClusters/aks-cluster'
                    Title      = 'Info-level control'
                    Severity   = 'info'
                    Detail     = ''
                    Compliant  = $false
                    LearnMoreUrl = ''
                    SchemaVersion = '1.0'
                }
            )
        }
        $rows = @(Normalize-Kubescape -ToolResult $infoInput)
        $rows.Count | Should -Be 1
        $rows[0].Severity | Should -Be 'Info'
    }

    It 'produces canonical ARM IDs via ConvertTo-CanonicalEntityId' {
        $rows = @(Normalize-Kubescape -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityId | Should -Match '^/subscriptions/[0-9a-f]'
            $r.EntityId | Should -Be $r.EntityId.ToLowerInvariant()
        }
    }
}
