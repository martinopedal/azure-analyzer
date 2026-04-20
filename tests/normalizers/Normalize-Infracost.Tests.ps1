#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Infracost.ps1')
}

Describe 'Normalize-Infracost' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\infracost\infracost-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns one normalized row per resource finding' {
        $rows = @(Normalize-Infracost -ToolResult $fixture)
        $rows.Count | Should -Be 3
    }

    It 'uses v2 schema rows with AzureResource entity type' {
        $rows = @(Normalize-Infracost -ToolResult $fixture)
        foreach ($r in $rows) {
            $r.SchemaVersion | Should -Be '2.0'
            $r.Source | Should -Be 'infracost'
            $r.EntityType | Should -Be 'AzureResource'
            $r.Platform | Should -Be 'Azure'
            $r.Category | Should -Be 'WAF Cost Optimization'
        }
    }

    It 'applies severity thresholds based on monthly cost' {
        $rows = @(Normalize-Infracost -ToolResult $fixture)
        ($rows | Where-Object { $_.Title -match 'kubernetes_cluster' } | Select-Object -First 1).Severity | Should -Be 'High'
        ($rows | Where-Object { $_.Title -match 'storage_account' } | Select-Object -First 1).Severity | Should -Be 'Medium'
        ($rows | Where-Object { $_.Title -match 'resource_group' } | Select-Object -First 1).Severity | Should -Be 'Low'
    }

    It 'sets Compliant true only when monthly cost is at or below 100' {
        $rows = @(Normalize-Infracost -ToolResult $fixture)
        ($rows | Where-Object { $_.Severity -eq 'Low' } | Select-Object -First 1).Compliant | Should -BeTrue
        ($rows | Where-Object { $_.Severity -eq 'High' } | Select-Object -First 1).Compliant | Should -BeFalse
        ($rows | Where-Object { $_.Severity -eq 'Medium' } | Select-Object -First 1).Compliant | Should -BeFalse
    }

    It 'attaches MonthlyCost and Currency for EntityStore folding' {
        $rows = @(Normalize-Infracost -ToolResult $fixture)
        foreach ($r in $rows) {
            $r.PSObject.Properties.Name | Should -Contain 'MonthlyCost'
            $r.PSObject.Properties.Name | Should -Contain 'Currency'
            $r.Currency | Should -Be 'USD'
        }
    }

    It 'returns empty array for failed wrapper output' {
        $rows = @(Normalize-Infracost -ToolResult $failedFixture)
        $rows.Count | Should -Be 0
    }
}
