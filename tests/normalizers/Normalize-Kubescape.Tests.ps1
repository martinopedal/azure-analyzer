#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Kubescape.ps1')
}

Describe 'Normalize-Kubescape' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\kubescape-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    It 'converts kubescape findings to schema v2 rows' {
        $results = Normalize-Kubescape -ToolResult $fixture
        @($results).Count | Should -Be 2
        $results[0].SchemaVersion | Should -Be '2.0'
        $results[0].Source | Should -Be 'kubescape'
        $results[0].Platform | Should -Be 'Azure'
        $results[0].EntityType | Should -Be 'AzureResource'
    }

    It 'extracts subscription and resource group from AKS ARM id' {
        $results = Normalize-Kubescape -ToolResult $fixture
        foreach ($row in $results) {
            $row.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000001'
            $row.ResourceGroup | Should -Be 'rg-aks-eastus'
        }
    }

    It 'maps CIS benchmark IDs into Controls[]' {
        $results = Normalize-Kubescape -ToolResult $fixture
        $results[0].Controls | Should -Contain 'CIS-5.2.8'
        $results[1].Controls | Should -Contain 'CIS-5.2.9'
    }

    It 'returns empty for failed envelopes' {
        Normalize-Kubescape -ToolResult $failedFixture | Should -BeNullOrEmpty
    }
}
