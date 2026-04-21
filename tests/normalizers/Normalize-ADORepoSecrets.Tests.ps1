#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-ADORepoSecrets.ps1')
}

Describe 'Normalize-ADORepoSecrets' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\ado-secrets\ado-repos-secrets-output.json') -Raw | ConvertFrom-Json
        $onPremFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\ado-onprem-repos.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns expected count with schema metadata' {
        $rows = @(Normalize-ADORepoSecrets -ToolResult $fixture)
        $rows.Count | Should -Be 3
        ($rows | Select-Object -ExpandProperty Source -Unique) | Should -Be 'ado-repos-secrets'
        ($rows | Select-Object -ExpandProperty Platform -Unique) | Should -Be 'ADO'
        ($rows | Select-Object -ExpandProperty EntityType -Unique) | Should -Be 'Repository'
    }

    It 'normalizes severity across critical/high/medium values' {
        $rows = @(Normalize-ADORepoSecrets -ToolResult $fixture)
        ($rows | Where-Object Severity -eq 'Critical').Count | Should -Be 1
        ($rows | Where-Object Severity -eq 'High').Count | Should -Be 1
        ($rows | Where-Object Severity -eq 'Medium').Count | Should -Be 1
    }

    It 'emits schema 2.2 security context fields' {
        $rows = @(Normalize-ADORepoSecrets -ToolResult $fixture)
        $critical = @($rows | Where-Object { $_.RuleId -eq 'github-pat' })[0]
        $critical.Pillar | Should -Be 'Security'
        $critical.Impact | Should -Be 'Critical'
        $critical.Effort | Should -Be 'High'
        $critical.DeepLinkUrl | Should -Match 'dev\.azure\.com'
        @($critical.BaselineTags) | Should -Contain 'github-pat'
        @($critical.BaselineTags) | Should -Contain 'high'
        @($critical.BaselineTags) | Should -Contain 'ruleId:github-pat'
        @($critical.EntityRefs) | Should -Contain 'ado://contoso/payments/repository/payments-api'
        @($critical.EntityRefs) | Should -Contain 'commit:aaaaaaaa11111111'
        @($critical.EvidenceUris | Where-Object { $_ -match '/commit/' }).Count | Should -BeGreaterThan 0
        @($critical.RemediationSnippets).Count | Should -BeGreaterThan 0
        $critical.ToolVersion | Should -Be 'gitleaks version 8.21.2'
    }

    It 'builds title with SecretType plus file and line for dedup safety' {
        $rows = @(Normalize-ADORepoSecrets -ToolResult $fixture)
        @($rows | Where-Object { $_.Title -eq 'github-pat in src/appsettings.json:8' }).Count | Should -Be 1
        @($rows | Where-Object { $_.Title -eq 'azure-storage-key in charts/api/values.yaml:22' }).Count | Should -Be 1
        @($rows | Where-Object { $_.Title -eq 'generic-api-key in test/testdata.txt:4' }).Count | Should -Be 1
    }

    It 'produces canonical ado:// repository entity IDs' {
        $rows = @(Normalize-ADORepoSecrets -ToolResult $fixture)
        foreach ($row in $rows) {
            $row.EntityId | Should -Match '^ado://contoso/payments/repository/payments-api$'
        }
    }

    It 'returns empty for failed wrapper results' {
        @(Normalize-ADORepoSecrets -ToolResult $failedFixture).Count | Should -Be 0
    }

    It 'normalizes on-prem allow-list skip findings as Info severity' {
        $rows = @(Normalize-ADORepoSecrets -ToolResult $onPremFixture)
        $rows.Count | Should -Be 1
        $rows[0].Severity | Should -Be 'Info'
        $rows[0].EntityId | Should -Be 'ado://contoso/payments/repository/payments-api'
        $rows[0].Pillar | Should -Be 'Security'
        $rows[0].Confidence | Should -Be 'Unknown'
    }
}
