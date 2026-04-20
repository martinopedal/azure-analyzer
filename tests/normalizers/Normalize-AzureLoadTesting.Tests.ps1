Describe 'Normalize-AzureLoadTesting' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-AzureLoadTesting.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'loadtesting' 'loadtesting-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty when Status is not Success' {
        $rows = @(Normalize-AzureLoadTesting -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $rows.Count | Should -Be 0
    }

    It 'emits one FindingRow per fixture finding' {
        $rows = @(Normalize-AzureLoadTesting -ToolResult $script:Fixture)
        $rows.Count | Should -Be 3
    }

    It 'maps to AzureResource entities and Azure platform' {
        $rows = @(Normalize-AzureLoadTesting -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.EntityType | Should -Be 'AzureResource'
            $row.Platform | Should -Be 'Azure'
            $row.Source | Should -Be 'loadtesting'
        }
    }

    It 'keeps severity and compliant values from wrapper findings' {
        $rows = @(Normalize-AzureLoadTesting -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.Id -like '*/failed' }).Severity | Should -Be 'High'
        ($rows | Where-Object { $_.Id -like '*/failed' }).Compliant | Should -BeFalse
        ($rows | Where-Object { $_.Id -like '*/regression/*' }).Severity | Should -Be 'Medium'
        ($rows | Where-Object { $_.Id -like '*/healthy' }).Severity | Should -Be 'Info'
        ($rows | Where-Object { $_.Id -like '*/healthy' }).Compliant | Should -BeTrue
    }

    It 'canonicalizes the Azure resource ID and extracts subscription/resource-group' {
        $rows = @(Normalize-AzureLoadTesting -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.EntityId | Should -Be $row.EntityId.ToLowerInvariant()
            $row.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $row.ResourceGroup | Should -Be 'perf-rg'
        }
    }

    It 'preserves load testing metadata extras' {
        $rows = @(Normalize-AzureLoadTesting -ToolResult $script:Fixture)
        $failed = $rows | Where-Object { $_.Id -like '*/failed' }
        $failed.TestName | Should -Be 'checkout'
        $failed.TestRunId | Should -Be 'testrun-001'
        $failed.FailureCause | Should -Be '5xx spike'

        $regressed = $rows | Where-Object { $_.Id -like '*/regression/*' }
        $regressed.MetricName | Should -Be 'ResponseTimeP95'
        $regressed.RegressionPercent | Should -Be 24.5
        $regressed.ThresholdPercent | Should -Be 10
    }
}
