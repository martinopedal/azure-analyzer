Describe 'Normalize-AppInsights' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-AppInsights.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'appinsights' 'appinsights-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty when Status is not Success' {
        $rows = @(Normalize-AppInsights -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $rows.Count | Should -Be 0
    }

    It 'emits one FindingRow per fixture finding' {
        $rows = @(Normalize-AppInsights -ToolResult $script:Fixture)
        $rows.Count | Should -Be 5
    }

    It 'maps to AzureResource entity type and Azure platform' {
        $rows = @(Normalize-AppInsights -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.EntityType | Should -Be 'AzureResource'
            $row.Platform | Should -Be 'Azure'
            $row.Source | Should -Be 'appinsights'
        }
    }

    It 'applies severity boundaries for slow requests and fixed severities for other query types' {
        $rows = @(Normalize-AppInsights -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/requests/get-orders' }).Severity | Should -Be 'High'
        ($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/requests/get-catalog' }).Severity | Should -Be 'Medium'
        ($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/dependencies/sql' }).Severity | Should -Be 'Medium'
        ($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/exceptions/nullref' }).Severity | Should -Be 'High'
    }

    It 'builds expected title patterns' {
        $rows = @(Normalize-AppInsights -ToolResult $script:Fixture)
        ($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/requests/get-orders' }).Title | Should -Be 'Slow request: GET /orders avg 31.2s over 22 calls'
        ($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/dependencies/sql' }).Title | Should -Be 'Dependency failures: sql-prod (SQL) failed 7 times'
        ($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/exceptions/nullref' }).Title | Should -Be 'Exception cluster: NullReferenceException hit 88 times'
    }

    It 'sets HTTPS portal fix links' {
        $rows = @(Normalize-AppInsights -ToolResult $script:Fixture)
        foreach ($row in $rows) {
            $row.LearnMoreUrl | Should -Match '^https://portal\.azure\.com/'
            $row.LearnMoreUrl | Should -Match '/overview$'
        }
    }

    It 'maps schema 2.2 appinsights metadata fields' {
        $rows = @(Normalize-AppInsights -ToolResult $script:Fixture)
        $request = @($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/requests/get-orders' })[0]
        $exception = @($rows | Where-Object { $_.Id -eq 'appinsights/appi-prod/exceptions/nullref' })[0]

        $request.Pillar | Should -Be 'PerformanceEfficiency'
        $exception.Pillar | Should -Be 'Reliability'
        $request.DeepLinkUrl | Should -Match '^https://portal\.azure\.com/#blade/Microsoft_OperationsManagementSuite_Workspace/AnalyticsBlade/'
        $request.BaselineTags | Should -Contain 'AppInsights-SlowRequests'
        $request.ScoreDelta | Should -Be 31.2
        $request.ToolVersion | Should -Be 'Az.ApplicationInsights/2.5.0'
        $request.EvidenceUris | Should -Contain $request.DeepLinkUrl
        $request.EvidenceUris | Should -Contain $request.LearnMoreUrl
        @($request.EntityRefs).Count | Should -BeGreaterThan 1
    }
}
