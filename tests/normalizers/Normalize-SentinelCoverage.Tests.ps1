#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Normalize-SentinelCoverage' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'normalizers' 'Normalize-SentinelCoverage.ps1')
        $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'sentinel' 'coverage-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns empty when Status is not Success' {
        $r = @(Normalize-SentinelCoverage -ToolResult ([pscustomobject]@{ Status = 'Skipped'; Findings = @() }))
        $r.Count | Should -Be 0
    }

    It 'returns empty when Findings is null' {
        $r = @(Normalize-SentinelCoverage -ToolResult ([pscustomobject]@{ Status = 'Success'; Findings = $null }))
        $r.Count | Should -Be 0
    }

    It 'emits one row per fixture finding (six categories)' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $rows.Count | Should -Be 6
    }

    It 'every row is EntityType=AzureResource and Platform=Azure' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityType | Should -Be 'AzureResource'
            $r.Platform   | Should -Be 'Azure'
            $r.Source     | Should -Be 'sentinel-coverage'
            $r.Compliant  | Should -BeFalse
        }
    }

    It 'EntityId is the canonical lowercased workspace ARM ID' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.EntityId | Should -Be $r.EntityId.ToLowerInvariant()
            $r.EntityId | Should -Match '/subscriptions/'
            $r.EntityId | Should -Match '/microsoft\.operationalinsights/workspaces/'
        }
    }

    It 'SubscriptionId and ResourceGroup are extracted from the workspace ARM ID' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        foreach ($r in $rows) {
            $r.SubscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $r.ResourceGroup  | Should -Be 'Sentinel-RG'
        }
    }

    It 'no-analytic-rules detection maps to High' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $r = $rows | Where-Object { $_.Id -eq 'sentinel/coverage/no-analytic-rules' }
        $r.Severity | Should -Be 'High'
        $r.AnalyticRuleCount | Should -Be 0
    }

    It 'disabled-rule detection maps to Medium and preserves rule extras' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $r = $rows | Where-Object { $_.Id -like 'sentinel/coverage/disabled-rule/*' }
        $r.Severity        | Should -Be 'Medium'
        $r.RuleId          | Should -Be 'rule-disabled-old'
        $r.RuleDisplayName | Should -Be 'Anomalous AAD sign-in (legacy)'
        $r.AgeDays         | Should -Be 42
    }

    It 'maps Schema 2.2 MITRE metadata and deep link for disabled rule findings' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $r = $rows | Where-Object { $_.Id -like 'sentinel/coverage/disabled-rule/*' }
        $r.Pillar           | Should -Be 'Security'
        $r.ToolVersion      | Should -Be 'securityinsights-2024-09-01+loganalytics-2020-08-01'
        $r.DeepLinkUrl      | Should -Match 'Microsoft_Azure_Security_Insights/MainMenuBlade'
        $r.MitreTactics     | Should -Be @('InitialAccess', 'CredentialAccess')
        $r.MitreTechniques  | Should -Be @('T1078', 'T1110')
        @($r.Frameworks).Count | Should -Be 1
        $r.Frameworks[0].Name | Should -Be 'MITRE ATT&CK'
        $r.Frameworks[0].Controls | Should -Be @('T1078', 'T1110')
        $r.EntityRefs | Should -Contain $r.EntityId
    }

    It 'few-connectors detection maps to Medium and preserves counts' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $r = $rows | Where-Object { $_.Id -eq 'sentinel/coverage/few-connectors' }
        $r.Severity       | Should -Be 'Medium'
        $r.ConnectorCount | Should -Be 1
        $r.MinExpected    | Should -Be 3
    }

    It 'watchlist-ttl detection maps to Medium and preserves alias / TTL' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $r = $rows | Where-Object { $_.Id -like 'sentinel/coverage/watchlist-ttl/*' }
        $r.Severity        | Should -Be 'Medium'
        $r.WatchlistAlias  | Should -Be 'HighValueAssets'
        $r.DefaultDuration | Should -Be 'P14D'
        $r.TtlDays         | Should -Be 14
    }

    It 'watchlist-empty detection maps to Low and preserves item count' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $r = $rows | Where-Object { $_.Id -like 'sentinel/coverage/watchlist-empty/*' }
        $r.Severity       | Should -Be 'Low'
        $r.WatchlistAlias | Should -Be 'VipUsers'
        $r.ItemCount      | Should -Be 0
    }

    It 'no-hunting-queries detection maps to Info' {
        $rows = @(Normalize-SentinelCoverage -ToolResult $script:Fixture)
        $r = $rows | Where-Object { $_.Id -eq 'sentinel/coverage/no-hunting-queries' }
        $r.Severity          | Should -Be 'Info'
        $r.HuntingQueryCount | Should -Be 0
    }

    It 'maps lowercase severity strings (e.g. "high") to canonical schema casing' {
        $tr = [pscustomobject]@{
            Status   = 'Success'
            Findings = @(
                [pscustomobject]@{ Id='x/critical'; Title='c'; Severity='critical';      Compliant=$false; ResourceId='/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/r/providers/Microsoft.OperationalInsights/workspaces/w'; Detail='d'; Remediation='r'; LearnMoreUrl='u'; Category='ThreatDetection' },
                [pscustomobject]@{ Id='x/high';     Title='h'; Severity='high';          Compliant=$false; ResourceId='/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/r/providers/Microsoft.OperationalInsights/workspaces/w'; Detail='d'; Remediation='r'; LearnMoreUrl='u'; Category='ThreatDetection' },
                [pscustomobject]@{ Id='x/medium';   Title='m'; Severity='medium';        Compliant=$false; ResourceId='/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/r/providers/Microsoft.OperationalInsights/workspaces/w'; Detail='d'; Remediation='r'; LearnMoreUrl='u'; Category='ThreatDetection' },
                [pscustomobject]@{ Id='x/low';      Title='l'; Severity='low';           Compliant=$false; ResourceId='/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/r/providers/Microsoft.OperationalInsights/workspaces/w'; Detail='d'; Remediation='r'; LearnMoreUrl='u'; Category='ThreatDetection' },
                [pscustomobject]@{ Id='x/info';     Title='i'; Severity='informational'; Compliant=$false; ResourceId='/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/r/providers/Microsoft.OperationalInsights/workspaces/w'; Detail='d'; Remediation='r'; LearnMoreUrl='u'; Category='ThreatDetection' }
            )
        }
        $rows = @(Normalize-SentinelCoverage -ToolResult $tr)
        $rows.Count | Should -Be 5
        ($rows | Where-Object { $_.Id -eq 'x/critical' }).Severity | Should -Be 'Critical'
        ($rows | Where-Object { $_.Id -eq 'x/high' }).Severity     | Should -Be 'High'
        ($rows | Where-Object { $_.Id -eq 'x/medium' }).Severity   | Should -Be 'Medium'
        ($rows | Where-Object { $_.Id -eq 'x/low' }).Severity      | Should -Be 'Low'
        ($rows | Where-Object { $_.Id -eq 'x/info' }).Severity     | Should -Be 'Info'
    }

    It 'skips findings with empty ResourceId' {
        $tr = [pscustomobject]@{
            Status   = 'Success'
            Findings = @(
                [pscustomobject]@{ Id='no-rid'; Title='t'; Severity='Low'; Compliant=$false; ResourceId=''; Detail='d'; Remediation='r'; LearnMoreUrl='u'; Category='ThreatDetection' }
            )
        }
        $rows = @(Normalize-SentinelCoverage -ToolResult $tr)
        $rows.Count | Should -Be 0
    }
}
