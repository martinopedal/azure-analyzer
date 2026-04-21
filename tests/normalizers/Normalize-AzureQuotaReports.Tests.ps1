Describe 'Normalize-AzureQuotaReports' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-AzureQuotaReports.ps1')
        $script:CompliantFixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'azure-quota' 'azure-quota-compliant.json') -Raw | ConvertFrom-Json
        $script:NearLimitFixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'azure-quota' 'azure-quota-near-limit.json') -Raw | ConvertFrom-Json
        $script:BreachFixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'azure-quota' 'azure-quota-breach.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when Status is not Success' {
        $rows = @(Normalize-AzureQuotaReports -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $rows.Count | Should -Be 0
    }

    It 'normalizes compliant records as Info with locked compliant formula' {
        $rows = @(Normalize-AzureQuotaReports -ToolResult $script:CompliantFixture)
        $rows.Count | Should -Be 1
        $rows[0].Compliant | Should -BeTrue
        $rows[0].Severity | Should -Be 'Info'
        $rows[0].EntityType | Should -Be 'Subscription'
        $rows[0].EntityId | Should -Be '11111111-1111-1111-1111-111111111111'
        $rows[0].Category | Should -Be 'Capacity'
        $rows[0].Pillar | Should -Be 'Reliability'
    }

    It 'maps near-limit noncompliant records to Medium severity' {
        $rows = @(Normalize-AzureQuotaReports -ToolResult $script:NearLimitFixture)
        $rows.Count | Should -Be 1
        $rows[0].Compliant | Should -BeFalse
        $rows[0].Severity | Should -Be 'Medium'
        $rows[0].Title | Should -Be 'Quota PublicIPAddresses in westeurope is at 92%'
        $rows[0].Detail | Should -Match 'CurrentValue=92'
        $rows[0].Detail | Should -Match 'Limit=100'
        $rows[0].Detail | Should -Match 'Region=westeurope'
        $rows[0].Detail | Should -Match 'SkuName=PublicIPAddresses'
    }

    It 'maps breach records to Critical and emits stable azure-quota rule id' {
        $rows = @(Normalize-AzureQuotaReports -ToolResult $script:BreachFixture)
        $rows.Count | Should -Be 1
        $rows[0].Compliant | Should -BeFalse
        $rows[0].Severity | Should -Be 'Critical'
        $rows[0].RuleId | Should -Be 'azure-quota:vm:standardNVADSA10v5Family:centralus'
    }
}

