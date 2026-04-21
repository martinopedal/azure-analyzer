#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-GhActionsBilling.ps1')

    $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\cicd-cost\gh-actions-billing-output.json') -Raw | ConvertFrom-Json
}

Describe 'Normalize-GhActionsBilling' {
    It 'returns rows for successful tool output' {
        $rows = @(Normalize-GhActionsBilling -ToolResult $script:Fixture)
        $rows.Count | Should -Be 3
    }

    It 'uses Repository entity type and GitHub platform' {
        $rows = @(Normalize-GhActionsBilling -ToolResult $script:Fixture)
        @($rows | Where-Object { $_.EntityType -ne 'Repository' }).Count | Should -Be 0
        @($rows | Where-Object { $_.Platform -ne 'GitHub' }).Count | Should -Be 0
    }

    It 'stamps RuleId values' {
        $rows = @(Normalize-GhActionsBilling -ToolResult $script:Fixture)
        @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.RuleId) }).Count | Should -Be 0
    }

    It 'maps Schema 2.2 ETL fields' {
        $rows = @(Normalize-GhActionsBilling -ToolResult $script:Fixture)
        @($rows | Where-Object { $_.Pillar -ne 'Cost Optimization' }).Count | Should -Be 0
        @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Impact) }).Count | Should -Be 0
        @($rows | Where-Object { $_.Effort -ne 'Low' }).Count | Should -Be 0
        @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.DeepLinkUrl) }).Count | Should -Be 0
        @($rows | Where-Object { $null -eq $_.ScoreDelta }).Count | Should -Be 0
        @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.ToolVersion) }).Count | Should -Be 0
        @($rows | Where-Object { @($_.EvidenceUris).Count -eq 0 }).Count | Should -Be 0
        @($rows | Where-Object { @($_.BaselineTags).Count -lt 2 }).Count | Should -Be 0
        @($rows | Where-Object { @($_.EntityRefs).Count -eq 0 }).Count | Should -Be 0
    }
}
