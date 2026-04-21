#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Powerpipe.ps1')
}

Describe 'Normalize-Powerpipe' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\powerpipe-output.json') -Raw | ConvertFrom-Json -Depth 100
        $results = @(Normalize-Powerpipe -ToolResult $fixture)
    }

    It 'returns one row per finding' {
        $results.Count | Should -Be 2
    }

    It 'maps to schema 2.2 rows' {
        foreach ($row in $results) {
            $row.SchemaVersion | Should -Be '2.2'
            $row.Source | Should -Be 'powerpipe'
            $row.Platform | Should -Be 'Azure'
            $row.EntityType | Should -Be 'AzureResource'
        }
    }

    It 'emits multi-framework metadata from tags as hashtable entries' {
        $first = $results | Where-Object { $_.RuleId -eq 'azure_cis_1_1_1' } | Select-Object -First 1
        @($first.Frameworks).Count | Should -Be 3
        @($first.Frameworks | Where-Object { $_.kind -eq 'CIS' -and $_.controlId -eq '1.1.1' }).Count | Should -Be 1
        @($first.Frameworks | Where-Object { $_.kind -eq 'NIST' -and $_.controlId -eq 'AC-2' }).Count | Should -Be 1
        @($first.Frameworks | Where-Object { $_.kind -eq 'NIST' -and $_.controlId -eq 'CA-7' }).Count | Should -Be 1
    }

    It 'emits baseline tags, evidence uris, remediation snippets, pillar and tool version' {
        $first = $results | Where-Object { $_.RuleId -eq 'azure_cis_1_1_1' } | Select-Object -First 1
        $first.BaselineTags | Should -Contain 'baseline:cis-azure-v1.5'
        $first.BaselineTags | Should -Contain 'release:preview'
        $first.EvidenceUris | Should -Contain 'https://example.test/powerpipe/rows/pp-1'
        @($first.RemediationSnippets).Count | Should -Be 1
        $first.Pillar | Should -Be 'Security'
        $first.ToolVersion | Should -Be 'powerpipe v1.2.3'
        $first.DeepLinkUrl | Should -Be 'https://hub.steampipe.io/mods/example/control/azure_cis_1_1_1'
    }

    It 'maps fallback subscription context when ResourceId is missing' {
        $second = $results | Where-Object { $_.RuleId -eq 'azure_nist_ca7' } | Select-Object -First 1
        $second.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
        $second.EntityId | Should -Match '^/subscriptions/11111111-1111-1111-1111-111111111111/'
        $second.ToolVersion | Should -Be 'powerpipe v1.2.3'
    }

    It 'returns empty for non-success result' {
        $empty = @(Normalize-Powerpipe -ToolResult ([pscustomobject]@{ Status = 'Failed'; Findings = @() }))
        $empty.Count | Should -Be 0
    }
}
