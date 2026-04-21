Describe 'Normalize-AzureCost' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-AzureCost.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'azure-cost-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when Status is not Success' {
        $r = @(Normalize-AzureCost -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $r.Count | Should -Be 0
    }

    It 'emits one Subscription finding + two AzureResource findings' {
        $rows = @(Normalize-AzureCost -ToolResult $script:Fixture)
        $rows.Count | Should -Be 3
        ($rows | Where-Object { $_.EntityType -eq 'Subscription' }).Count  | Should -Be 1
        ($rows | Where-Object { $_.EntityType -eq 'AzureResource' }).Count | Should -Be 2
    }

    It 'every row has Severity=Info / Compliant=true / Category=Cost / Platform=Azure' {
        $rows = @(Normalize-AzureCost -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.Severity  | Should -Be 'Info'
            $r.Compliant | Should -BeTrue
            $r.Category  | Should -Be 'Cost'
            $r.Platform  | Should -Be 'Azure'
            $r.Source    | Should -Be 'azure-cost'
        }
    }

    It 'emits Schema 2.2 cost metadata fields for each finding' {
        $rows = @(Normalize-AzureCost -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.Pillar | Should -Be 'CostOptimization'
            @($r.Frameworks).Count | Should -BeGreaterThan 0
            @($r.Frameworks | Where-Object { $_.kind -eq 'FinOps Foundation' }).Count | Should -BeGreaterThan 0
            $r.Impact | Should -Not -BeNullOrEmpty
            $r.Effort | Should -Not -BeNullOrEmpty
            $r.DeepLinkUrl | Should -Match 'portal\.azure\.com'
            $r.DeepLinkUrl | Should -Match 'subscriptionId='
            @($r.RemediationSnippets).Count | Should -BeGreaterThan 0
            @($r.EvidenceUris).Count | Should -BeGreaterThan 0
            @($r.BaselineTags).Count | Should -BeGreaterThan 1
            $r.BaselineTags | Should -Contain 'cost'
            $r.ScoreDelta | Should -BeGreaterThan 0
            @($r.EntityRefs).Count | Should -BeGreaterThan 0
            $r.ToolVersion | Should -Be 'Microsoft.Consumption/usageDetails@2021-10-01'
        }
    }

    It 'attaches MonthlyCost and Currency to each finding' {
        $rows = @(Normalize-AzureCost -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.PSObject.Properties.Name | Should -Contain 'MonthlyCost'
            $r.PSObject.Properties.Name | Should -Contain 'Currency'
            $r.Currency    | Should -Be 'USD'
            $r.MonthlyCost | Should -BeGreaterThan 0
        }
        $sub = $rows | Where-Object { $_.EntityType -eq 'Subscription' }
        $sub.MonthlyCost | Should -Be 1234.56
    }

    It 'builds Cost Management deep links with subscription and resource-group query string' {
        $rows = @(Normalize-AzureCost -ToolResult $script:Fixture)
        $sub = $rows | Where-Object { $_.EntityType -eq 'Subscription' } | Select-Object -First 1
        $sub.DeepLinkUrl | Should -Match 'subscriptionId=11111111-1111-1111-1111-111111111111'

        $res = $rows | Where-Object { $_.EntityType -eq 'AzureResource' } | Select-Object -First 1
        $res.DeepLinkUrl | Should -Match 'resourceGroup=prod'
        $res.DeepLinkUrl | Should -Match 'resourceId='
    }

    It 'canonicalizes resource IDs and pulls SubscriptionId / ResourceGroup from them' {
        $rows = @(Normalize-AzureCost -ToolResult $script:Fixture)
        $res = $rows | Where-Object { $_.EntityType -eq 'AzureResource' } | Select-Object -First 1
        $res.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
        $res.ResourceGroup  | Should -Be 'prod'
    }
}
