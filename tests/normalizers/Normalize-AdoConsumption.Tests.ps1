#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-AdoConsumption.ps1')

    $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\cicd-cost\ado-consumption-output.json') -Raw | ConvertFrom-Json
}

Describe 'Normalize-AdoConsumption' {
    It 'returns rows for successful tool output' {
        $rows = @(Normalize-AdoConsumption -ToolResult $script:Fixture)
        $rows.Count | Should -Be 3
    }

    It 'uses AdoProject entity type with canonical ado:// IDs' {
        $rows = @(Normalize-AdoConsumption -ToolResult $script:Fixture)
        @($rows | Where-Object { $_.EntityType -ne 'AdoProject' }).Count | Should -Be 0
        @($rows | Where-Object { $_.EntityId -notmatch '^ado://' }).Count | Should -Be 0
    }

    It 'stamps RuleId values' {
        $rows = @(Normalize-AdoConsumption -ToolResult $script:Fixture)
        @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.RuleId) }).Count | Should -Be 0
    }

    It 'maps schema 2.2 governance metadata' {
        $rows = @(Normalize-AdoConsumption -ToolResult $script:Fixture)
        $share = $rows | Where-Object RuleId -eq 'Consumption-MinuteShareHigh' | Select-Object -First 1
        $regression = $rows | Where-Object RuleId -eq 'Consumption-DurationRegression' | Select-Object -First 1
        $fail = $rows | Where-Object RuleId -eq 'Consumption-FailRateHigh' | Select-Object -First 1

        $share.Pillar | Should -Be 'Cost Optimization'
        $share.Impact | Should -Be 'High'
        $share.Effort | Should -Be 'Low'
        $share.DeepLinkUrl | Should -Match '_a=analytics'
        $share.EvidenceUris | Should -Contain 'https://dev.azure.com/contoso/payments/_build'
        $share.BaselineTags | Should -Contain 'Consumption-MinuteShareHigh'
        $share.EntityRefs | Should -Contain 'AdoProject/contoso/payments'
        $share.ToolVersion | Should -Be '2.58.0'

        $regression.ScoreDelta | Should -Be 47.5
        $fail.Pillar | Should -Be 'Operational Excellence'
    }
}
