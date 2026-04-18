Describe 'Normalize-SentinelIncidents' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-SentinelIncidents.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'sentinel-incidents-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty array when Status is not Success' {
        $r = @(Normalize-SentinelIncidents -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $r.Count | Should -Be 0
    }

    It 'returns empty array when Findings is null' {
        $r = @(Normalize-SentinelIncidents -ToolResult ([pscustomobject]@{ Status = 'Success'; Findings = $null }))
        $r.Count | Should -Be 0
    }

    It 'emits one row per incident from fixture' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        $rows.Count | Should -Be 3
    }

    It 'all rows are EntityType=AzureResource (workspace-scoped)' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityType | Should -Be 'AzureResource'
        }
    }

    It 'High incident maps to Severity=High with Compliant=false' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        $high = $rows | Where-Object { $_.Title -like '*anonymous IP*' }
        $high.Severity  | Should -Be 'High'
        $high.Compliant | Should -BeFalse
        $high.Category  | Should -Be 'ThreatDetection'
    }

    It 'Medium incident maps correctly' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        $med = $rows | Where-Object { $_.Title -like '*resource deployment*' }
        $med.Severity | Should -Be 'Medium'
        $med.Compliant | Should -BeFalse
    }

    It 'Informational severity maps to Info' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        $info = $rows | Where-Object { $_.Title -like '*Identity Protection*' }
        $info.Severity | Should -Be 'Info'
    }

    It 'SubscriptionId and ResourceGroup are extracted from workspace ARM ID' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $r.ResourceGroup  | Should -Be 'sentinel-rg'
        }
    }

    It 'EntityId is a canonical lowercase ARM ID' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityId | Should -Match '/subscriptions/'
            $r.EntityId | Should -Be $r.EntityId.ToLowerInvariant()
        }
    }

    It 'extra Sentinel fields are attached via Add-Member' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        $high = $rows | Where-Object { $_.Title -like '*anonymous IP*' }
        $high.IncidentNumber  | Should -Be '42'
        $high.IncidentStatus  | Should -Be 'Active'
        $high.AlertCount      | Should -Be 3
        $high.Classification  | Should -Be 'TruePositive'
        $high.ProviderName    | Should -Be 'Azure Sentinel'
    }

    It 'every row has Source=sentinel-incidents and Platform=Azure' {
        $rows = @(Normalize-SentinelIncidents -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.Source   | Should -Be 'sentinel-incidents'
            $r.Platform | Should -Be 'Azure'
        }
    }
}
