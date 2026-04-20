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
}
