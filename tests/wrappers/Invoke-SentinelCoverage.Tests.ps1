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
                        @{ name = 'rule-stale-1';   properties = @{ enabled = $false; displayName = 'Rule B'; lastModifiedUtc = (Get-Date).ToUniversalTime().AddDays(-60).ToString('o') } }
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
            if ($u -match '/providers/Microsoft\.SecurityInsights/dataConnectors\?')  { return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @( @{ name='c1' }, @{ name='c2' }, @{ name='c3' }, @{ name='c4' } ) } | ConvertTo-Json -Depth 10) } }
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
