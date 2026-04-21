#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here     = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper  = Join-Path $script:RepoRoot 'modules' 'Invoke-SentinelCoverage.ps1'
    $script:WsId     = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/ws'
}

Describe 'Invoke-SentinelCoverage: error / skip paths' {
    Context 'when Az.Accounts module is missing' {
        BeforeAll {
            Mock Get-Module { $null }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'returns Status = Skipped' { $script:r.Status | Should -Be 'Skipped' }
        It 'mentions Az.Accounts'      { $script:r.Message | Should -Match 'Az.Accounts' }
        It 'has Source = sentinel-coverage' { $script:r.Source | Should -Be 'sentinel-coverage' }
        It 'has SchemaVersion 1.0'     { $script:r.SchemaVersion | Should -Be '1.0' }
    }

    Context 'when not signed in' {
        BeforeAll {
            Mock Get-Module    { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { $null }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'returns Status = Skipped'      { $script:r.Status | Should -Be 'Skipped' }
        It 'mentions sign-in'              { $script:r.Message | Should -Match 'Not signed in' }
    }

    Context 'when WorkspaceResourceId format is invalid' {
        BeforeAll {
            Mock Get-Module    { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext { [PSCustomObject]@{ Account = 'u@x' } }
            $script:r = & $script:Wrapper -WorkspaceResourceId '/subscriptions/bad'
        }
        It 'returns Status = Failed'  { $script:r.Status | Should -Be 'Failed' }
        It 'mentions invalid format'  { $script:r.Message | Should -Match 'Invalid WorkspaceResourceId' }
    }

    Context 'when alertRules returns HTTP 404 (Sentinel not onboarded)' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod { [PSCustomObject]@{ StatusCode = 404; Content = '{"error":"not found"}' } }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'returns Status = Skipped'                 { $script:r.Status | Should -Be 'Skipped' }
        It 'mentions Sentinel not onboarded'          { $script:r.Message | Should -Match 'not onboarded|not available' }
    }

    Context 'when alertRules call throws' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod { throw 'API broke' }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'returns Status = Failed' { $script:r.Status | Should -Be 'Failed' }
        It 'message is non-empty'    { $script:r.Message | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Invoke-SentinelCoverage: happy path with all six detection categories firing' {
    BeforeAll {
        Mock Get-Module    { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'u@x' } }

        # Use a single `if` chain matching the URI shape; everything else returns 200 with empty list.
        Mock Invoke-AzRestMethod {
            param($Method, $Uri)
            $u = [string]$Uri
            if ($u -match '/providers/Microsoft\.SecurityInsights/alertRules\?') {
                $payload = @{
                    value = @(
                        @{ name = 'rule-enabled-1'; properties = @{ enabled = $true;  displayName = 'Rule A'; lastModifiedUtc = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o') } },
                        @{ name = 'rule-stale-1';   properties = @{ enabled = $false; displayName = 'Rule B'; lastModifiedUtc = (Get-Date).ToUniversalTime().AddDays(-60).ToString('o'); tactics = @('InitialAccess'); techniques = @('T1078') } }
                    )
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = ($payload | ConvertTo-Json -Depth 10) }
            }
            if ($u -match '/providers/Microsoft\.SecurityInsights/dataConnectors\?') {
                return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @( @{ name = 'AzureActivity'; kind = 'AzureActivityLog'; properties = @{} } ) } | ConvertTo-Json -Depth 10) }
            }
            if ($u -match '/providers/Microsoft\.SecurityInsights/watchlists/[^/]+/watchlistItems\?') {
                if ($u -match 'watchlists/EmptyWl/watchlistItems') {
                    return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[{"name":"item-1"}]}' }
            }
            if ($u -match '/providers/Microsoft\.SecurityInsights/watchlists\?') {
                $payload = @{
                    value = @(
                        @{ name = 'wl-1'; properties = @{ watchlistAlias = 'ShortTtl'; defaultDuration = 'P14D' } },
                        @{ name = 'wl-2'; properties = @{ watchlistAlias = 'EmptyWl';  defaultDuration = 'P90D' } }
                    )
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = ($payload | ConvertTo-Json -Depth 10) }
            }
            if ($u -match '/savedSearches\?') {
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }

        $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        $script:ids = @($script:r.Findings | ForEach-Object { $_.Id })
    }

    It 'returns Status = Success'                                  { $script:r.Status | Should -Be 'Success' }
    It 'detects the disabled stale analytic rule'                  { $script:ids | Should -Contain 'sentinel/coverage/disabled-rule/rule-stale-1' }
    It 'does NOT flag the enabled fresh rule'                      { $script:ids | Should -Not -Contain 'sentinel/coverage/disabled-rule/rule-enabled-1' }
    It 'detects the under-monitored connector count'               { $script:ids | Should -Contain 'sentinel/coverage/few-connectors' }
    It 'detects the short-TTL watchlist'                           { $script:ids | Should -Contain 'sentinel/coverage/watchlist-ttl/ShortTtl' }
    It 'detects the empty watchlist'                               { $script:ids | Should -Contain 'sentinel/coverage/watchlist-empty/EmptyWl' }
    It 'does NOT flag the populated watchlist as empty'            { $script:ids | Should -Not -Contain 'sentinel/coverage/watchlist-empty/ShortTtl' }
    It 'detects the missing hunting queries'                       { $script:ids | Should -Contain 'sentinel/coverage/no-hunting-queries' }
    It 'does NOT raise the no-analytic-rules finding when rules exist' {
        $script:ids | Should -Not -Contain 'sentinel/coverage/no-analytic-rules'
    }
    It 'all findings are Compliant=false' {
        foreach ($f in $script:r.Findings) { $f.Compliant | Should -BeFalse }
    }
    It 'stale disabled rule includes MITRE fields and framework controls' {
        $f = $script:r.Findings | Where-Object { $_.Id -eq 'sentinel/coverage/disabled-rule/rule-stale-1' }
        $f.MitreTactics    | Should -Be @('InitialAccess')
        $f.MitreTechniques | Should -Be @('T1078')
        @($f.Frameworks).Count | Should -Be 1
        $f.Frameworks[0].Name | Should -Be 'MITRE ATT&CK'
        $f.Frameworks[0].Controls | Should -Be @('T1078')
    }
    It 'all findings include Schema 2.2 security metadata' {
        foreach ($f in $script:r.Findings) {
            $f.Pillar      | Should -Be 'Security'
            $f.ToolVersion | Should -Not -BeNullOrEmpty
            $f.DeepLinkUrl | Should -Match 'Microsoft_Azure_Security_Insights/MainMenuBlade'
        }
    }
    It 'all findings target the workspace ARM resource' {
        foreach ($f in $script:r.Findings) { $f.ResourceId | Should -Be $script:WsId }
    }
    It 'message reports inventory counts' {
        $script:r.Message | Should -Match 'analyticRules: 2'
        $script:r.Message | Should -Match 'connectors: 1'
        $script:r.Message | Should -Match 'watchlists: 2'
    }
}

Describe 'Invoke-SentinelCoverage: empty-workspace (no analytic rules) raises High finding' {
    BeforeAll {
        Mock Get-Module    { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'u@x' } }
        Mock Invoke-AzRestMethod {
            param($Method, $Uri)
            $u = [string]$Uri
            if ($u -match '/providers/Microsoft\.SecurityInsights/alertRules\?')      { return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' } }
            if ($u -match '/providers/Microsoft\.SecurityInsights/dataConnectors\?')  { return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @(
                @{ name='c1'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } },
                @{ name='c2'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } },
                @{ name='c3'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } },
                @{ name='c4'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } }
            ) } | ConvertTo-Json -Depth 10) } }
            if ($u -match '/providers/Microsoft\.SecurityInsights/watchlists\?')      { return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' } }
            if ($u -match '/savedSearches\?')                                         { return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @( @{ name='hq-1'; properties = @{ category = 'Hunting Queries' } } ) } | ConvertTo-Json -Depth 10) } }
            return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }
        $script:r   = & $script:Wrapper -WorkspaceResourceId $script:WsId
        $script:ids = @($script:r.Findings | ForEach-Object { $_.Id })
    }
    It 'returns Status = Success'                       { $script:r.Status | Should -Be 'Success' }
    It 'raises the no-analytic-rules High finding'      { $script:ids | Should -Contain 'sentinel/coverage/no-analytic-rules' }
    It 'does NOT raise the few-connectors finding when 4 connectors exist' { $script:ids | Should -Not -Contain 'sentinel/coverage/few-connectors' }
    It 'does NOT raise the no-hunting-queries finding when at least one exists' { $script:ids | Should -Not -Contain 'sentinel/coverage/no-hunting-queries' }
    It 'no-analytic-rules finding is Severity = High' {
        $f = $script:r.Findings | Where-Object { $_.Id -eq 'sentinel/coverage/no-analytic-rules' }
        $f.Severity | Should -Be 'High'
    }
}

Describe 'Invoke-SentinelCoverage: v1 envelope contract' {
    BeforeAll {
        Mock Get-Module { $null }
        $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
    }
    It 'has SchemaVersion 1.0'              { $script:r.SchemaVersion | Should -Be '1.0' }
    It 'has Source = sentinel-coverage'     { $script:r.Source | Should -Be 'sentinel-coverage' }
    It 'has Subscription extracted from ARM ID' { $script:r.Subscription | Should -Be '00000000-0000-0000-0000-000000000000' }
    It 'has ISO 8601 Timestamp'             { $script:r.Timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T' }
}


Describe 'Invoke-SentinelCoverage: rubberduck-consensus follow-up (PR after #180)' {

    Context 'onboarding probe: 404 short-circuits to Skipped' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod {
                param($Method, $Uri)
                $u = [string]$Uri
                if ($u -match '/onboardingStates/default') {
                    return [PSCustomObject]@{ StatusCode = 404; Content = '{"error":"not found"}' }
                }
                throw "alertRules MUST NOT be called when probe is 404 (got $u)"
            }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'returns Status = Skipped'                       { $script:r.Status | Should -Be 'Skipped' }
        It 'message names onboardingStates as the source'  { $script:r.Message | Should -Match 'onboardingStates' }
        It 'emits zero findings'                            { @($script:r.Findings).Count | Should -Be 0 }
    }

    Context 'onboarding probe: 401 / 403 = Skipped (perms denied)' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod {
                param($Method, $Uri)
                if (([string]$Uri) -match '/onboardingStates/default') {
                    return [PSCustomObject]@{ StatusCode = 403; Content = '{"error":"forbidden"}' }
                }
                throw 'should not reach alertRules'
            }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'returns Status = Skipped'                       { $script:r.Status | Should -Be 'Skipped' }
        It 'message names the missing role'                 { $script:r.Message | Should -Match 'Sentinel Reader' }
    }

    Context 'pagination: alertRules nextLink is followed and items aggregated' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod {
                param($Method, $Uri)
                $u = [string]$Uri
                if ($u -match '/onboardingStates/default') { return [PSCustomObject]@{ StatusCode = 200; Content = '{"name":"default"}' } }
                if ($u -match '/providers/Microsoft\.SecurityInsights/alertRules\?') {
                    # First page returns 1 enabled + 1 stale-disabled, plus a nextLink to page 2
                    $p1 = @{
                        nextLink = 'https://management.azure.com/page2?token=abc'
                        value = @(
                            @{ name = 'r1'; properties = @{ enabled = $true;  displayName = 'r1' } },
                            @{ name = 'r2'; properties = @{ enabled = $false; displayName = 'r2'; lastModifiedUtc = (Get-Date).ToUniversalTime().AddDays(-90).ToString('o') } }
                        )
                    }
                    return [PSCustomObject]@{ StatusCode = 200; Content = ($p1 | ConvertTo-Json -Depth 10) }
                }
                if ($u -eq 'https://management.azure.com/page2?token=abc') {
                    # Second page returns another stale-disabled rule, no nextLink
                    $p2 = @{ value = @(
                        @{ name = 'r3'; properties = @{ enabled = $false; displayName = 'r3'; lastModifiedUtc = (Get-Date).ToUniversalTime().AddDays(-90).ToString('o') } }
                    ) }
                    return [PSCustomObject]@{ StatusCode = 200; Content = ($p2 | ConvertTo-Json -Depth 10) }
                }
                # Everything else: 200 empty
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            $script:r   = & $script:Wrapper -WorkspaceResourceId $script:WsId
            $script:ids = @($script:r.Findings | ForEach-Object { $_.Id })
        }
        It 'returns Status = Success'                       { $script:r.Status | Should -Be 'Success' }
        It 'flagged the page-1 stale rule'                  { $script:ids | Should -Contain 'sentinel/coverage/disabled-rule/r2' }
        It 'flagged the page-2 stale rule (nextLink walked)' { $script:ids | Should -Contain 'sentinel/coverage/disabled-rule/r3' }
        It 'message reports 3 analyticRules in total'       { $script:r.Message | Should -Match 'analyticRules: 3' }
    }

    Context 'connectors: filter to Enabled-state dataTypes (registered != enabled)' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod {
                param($Method, $Uri)
                $u = [string]$Uri
                if ($u -match '/onboardingStates/default') { return [PSCustomObject]@{ StatusCode = 200; Content = '{"name":"default"}' } }
                if ($u -match '/providers/Microsoft\.SecurityInsights/alertRules\?') {
                    return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @( @{ name='r1'; properties = @{ enabled=$true; displayName='r1' } } ) } | ConvertTo-Json -Depth 10) }
                }
                if ($u -match '/providers/Microsoft\.SecurityInsights/dataConnectors\?') {
                    # 5 registered, but only 2 with at least one Enabled dataType
                    $payload = @{ value = @(
                        @{ name='c1'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } },
                        @{ name='c2'; properties = @{ dataTypes = @{ Alerts = @{ state = 'Enabled' } } } },
                        @{ name='c3'; properties = @{ dataTypes = @{ Logs = @{ state = 'Disabled' } } } },
                        @{ name='c4'; properties = @{ dataTypes = @{ Logs = @{ state = 'Disabled' } } } },
                        @{ name='c5'; properties = @{ } }
                    ) }
                    return [PSCustomObject]@{ StatusCode = 200; Content = ($payload | ConvertTo-Json -Depth 10) }
                }
                if ($u -match '/savedSearches\?') { return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @( @{ name='hq'; properties = @{ category='Hunting Queries' } } ) } | ConvertTo-Json -Depth 10) } }
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
            $script:fc = @($script:r.Findings | Where-Object { $_.Id -eq 'sentinel/coverage/few-connectors' })
        }
        It 'still raises few-connectors when only 2/5 are Enabled' { $script:fc.Count | Should -Be 1 }
        It 'message text reports the enabled count, not the registered count' {
            $script:fc[0].Title | Should -Match 'only 2 enabled data connector'
        }
        It 'inventory message reports both registered and enabled counts' {
            $script:r.Message | Should -Match 'connectors: 5 \(enabled: 2\)'
        }
    }

    Context 'connectors: 3+ Enabled means no finding' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod {
                param($Method, $Uri)
                $u = [string]$Uri
                if ($u -match '/onboardingStates/default') { return [PSCustomObject]@{ StatusCode = 200; Content = '{"name":"default"}' } }
                if ($u -match '/providers/Microsoft\.SecurityInsights/alertRules\?') {
                    return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @( @{ name='r1'; properties = @{ enabled=$true; displayName='r1' } } ) } | ConvertTo-Json -Depth 10) }
                }
                if ($u -match '/providers/Microsoft\.SecurityInsights/dataConnectors\?') {
                    $payload = @{ value = @(
                        @{ name='c1'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } },
                        @{ name='c2'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } },
                        @{ name='c3'; properties = @{ dataTypes = @{ Logs = @{ state = 'Enabled' } } } }
                    ) }
                    return [PSCustomObject]@{ StatusCode = 200; Content = ($payload | ConvertTo-Json -Depth 10) }
                }
                if ($u -match '/savedSearches\?') { return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @( @{ name='hq'; properties = @{ category='Hunting Queries' } } ) } | ConvertTo-Json -Depth 10) } }
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            $script:r = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'does NOT raise few-connectors' { @($script:r.Findings | Where-Object { $_.Id -eq 'sentinel/coverage/few-connectors' }).Count | Should -Be 0 }
    }

    Context 'LookbackDays: parameter drives the disabled-rule staleness threshold' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod {
                param($Method, $Uri)
                $u = [string]$Uri
                if ($u -match '/onboardingStates/default') { return [PSCustomObject]@{ StatusCode = 200; Content = '{"name":"default"}' } }
                if ($u -match '/providers/Microsoft\.SecurityInsights/alertRules\?') {
                    # Disabled rule, 20 days old. Should fire at LookbackDays=7, NOT at LookbackDays=60.
                    $payload = @{ value = @(
                        @{ name='r-20d'; properties = @{ enabled = $false; displayName = '20-day-old'; lastModifiedUtc = (Get-Date).ToUniversalTime().AddDays(-20).ToString('o') } }
                    ) }
                    return [PSCustomObject]@{ StatusCode = 200; Content = ($payload | ConvertTo-Json -Depth 10) }
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            $script:r7  = & $script:Wrapper -WorkspaceResourceId $script:WsId -LookbackDays 7
            $script:r60 = & $script:Wrapper -WorkspaceResourceId $script:WsId -LookbackDays 60
            $script:ids7  = @($script:r7.Findings  | ForEach-Object { $_.Id })
            $script:ids60 = @($script:r60.Findings | ForEach-Object { $_.Id })
        }
        It 'flags the 20-day-old rule when LookbackDays=7'      { $script:ids7  | Should -Contain 'sentinel/coverage/disabled-rule/r-20d' }
        It 'does NOT flag the 20-day-old rule when LookbackDays=60' { $script:ids60 | Should -Not -Contain 'sentinel/coverage/disabled-rule/r-20d' }
        It 'finding title reflects the LookbackDays value' {
            $f = $script:r7.Findings | Where-Object { $_.Id -eq 'sentinel/coverage/disabled-rule/r-20d' }
            $f.Title | Should -Match 'disabled >7 days'
        }
    }

    Context 'watchlist alias: URL-encoded before being placed into watchlistItems URI' {
        BeforeAll {
            Mock Get-Module        { [PSCustomObject]@{ Name = 'Az.Accounts' } }
            Mock Get-AzContext     { [PSCustomObject]@{ Account = 'u@x' } }
            Mock Invoke-AzRestMethod {
                param($Method, $Uri)
                $u = [string]$Uri
                if ($u -match '/onboardingStates/default') { return [PSCustomObject]@{ StatusCode = 200; Content = '{"name":"default"}' } }
                if ($u -match '/providers/Microsoft\.SecurityInsights/alertRules\?') { return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' } }
                if ($u -match '/providers/Microsoft\.SecurityInsights/watchlists/[^?]+/watchlistItems\?') { return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' } }
                if ($u -match '/providers/Microsoft\.SecurityInsights/watchlists\?') {
                    $payload = @{ value = @( @{ name='w1'; properties = @{ watchlistAlias = 'My Alias With Spaces'; defaultDuration = 'P90D' } } ) }
                    return [PSCustomObject]@{ StatusCode = 200; Content = ($payload | ConvertTo-Json -Depth 10) }
                }
                return [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            $null = & $script:Wrapper -WorkspaceResourceId $script:WsId
        }
        It 'invoked watchlistItems with URL-encoded alias (AbsoluteUri preserves %20)' {
            Should -Invoke Invoke-AzRestMethod -Scope Context -ParameterFilter {
                $u = if ($Uri -is [Uri]) { $Uri.AbsoluteUri } else { [string]$Uri }
                $u -match 'watchlists/My%20Alias%20With%20Spaces/watchlistItems'
            }
        }
        It 'never sent watchlistItems with raw (unencoded) alias on the wire' {
            Should -Invoke Invoke-AzRestMethod -Scope Context -Times 0 -ParameterFilter {
                $u = if ($Uri -is [Uri]) { $Uri.AbsoluteUri } else { [string]$Uri }
                $u -match 'watchlists/My Alias With Spaces/watchlistItems'
            }
        }
    }
}
