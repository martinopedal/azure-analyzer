#Requires -Version 7.4

<#
.SYNOPSIS
    Pester tests for modules/shared/RateLimit.ps1.

.DESCRIPTION
    Validates the provider throttle state machine: defaults per provider,
    Retry-After header parsing, circuit-breaker open/close, concurrency-limit
    gate, and low-quota throttling. State-only tests, no real concurrency.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\modules\shared\RateLimit.ps1')
}

Describe 'New-ProviderThrottleState' {

    It 'applies the documented per-provider concurrency defaults' -ForEach @(
        @{ Provider = 'Azure';  Expected = 8 }
        @{ Provider = 'Graph';  Expected = 4 }
        @{ Provider = 'ADO';    Expected = 2 }
        @{ Provider = 'GitHub'; Expected = 1 }
    ) {
        $state = New-ProviderThrottleState -Provider $Provider
        $state.Provider          | Should -Be $Provider
        $state.ConcurrencyLimit  | Should -Be $Expected
        $state.ActiveRequests    | Should -Be 0
        $state.ConsecutiveFailures | Should -Be 0
    }

    It 'honors an explicit -ConcurrencyLimit override' {
        $state = New-ProviderThrottleState -Provider 'Azure' -ConcurrencyLimit 32
        $state.ConcurrencyLimit | Should -Be 32
    }

    It 'falls back to default when -ConcurrencyLimit is zero' {
        $state = New-ProviderThrottleState -Provider 'Graph' -ConcurrencyLimit 0
        $state.ConcurrencyLimit | Should -Be 4
    }

    It 'rejects unknown providers via parameter validation' {
        { New-ProviderThrottleState -Provider 'Bogus' } | Should -Throw
    }
}

Describe 'Test-ShouldThrottle' {

    It 'does not throttle a fresh state' {
        $state = New-ProviderThrottleState -Provider 'Azure'
        $verdict = Test-ShouldThrottle -State $state
        $verdict.ShouldThrottle | Should -BeFalse
        $verdict.Reason         | Should -BeNullOrEmpty
    }

    It 'throttles with reason CircuitOpen when CircuitOpenUntil is in the future' {
        $state = New-ProviderThrottleState -Provider 'Azure'
        $state.CircuitOpenUntil = (Get-Date).AddSeconds(30)
        $verdict = Test-ShouldThrottle -State $state
        $verdict.ShouldThrottle | Should -BeTrue
        $verdict.Reason         | Should -Be 'CircuitOpen'
        $verdict.DelaySeconds   | Should -BeGreaterThan 0
    }

    It 'throttles with reason RetryAfter when RetryAfterUntil is in the future' {
        $state = New-ProviderThrottleState -Provider 'Graph'
        $state.RetryAfterUntil = (Get-Date).AddSeconds(15)
        $verdict = Test-ShouldThrottle -State $state
        $verdict.ShouldThrottle | Should -BeTrue
        $verdict.Reason         | Should -Be 'RetryAfter'
    }

    It 'throttles with reason LowQuota when remaining ratio drops below 10 percent' {
        $state = New-ProviderThrottleState -Provider 'Graph'
        $state.InitialQuota   = 100
        $state.RemainingQuota = 5
        $verdict = Test-ShouldThrottle -State $state
        $verdict.ShouldThrottle | Should -BeTrue
        $verdict.Reason         | Should -Be 'LowQuota'
    }

    It 'throttles with reason ConcurrencyLimit when ActiveRequests reaches the limit' {
        $state = New-ProviderThrottleState -Provider 'GitHub' -ConcurrencyLimit 1
        $state.ActiveRequests = 1
        $verdict = Test-ShouldThrottle -State $state
        $verdict.ShouldThrottle | Should -BeTrue
        $verdict.Reason         | Should -Be 'ConcurrencyLimit'
    }
}

Describe 'Update-ThrottleState' {

    It 'increments ConsecutiveFailures on 429 responses' {
        $state = New-ProviderThrottleState -Provider 'Azure'
        Update-ThrottleState -State $state -StatusCode 429
        $state.ConsecutiveFailures | Should -Be 1
        Update-ThrottleState -State $state -StatusCode 429
        $state.ConsecutiveFailures | Should -Be 2
    }

    It 'opens the circuit when ConsecutiveFailures crosses the threshold' {
        $state = New-ProviderThrottleState -Provider 'Azure'
        for ($i = 0; $i -lt 5; $i++) {
            Update-ThrottleState -State $state -StatusCode 429
        }
        $state.ConsecutiveFailures | Should -BeGreaterOrEqual 5
        $state.CircuitOpenUntil    | Should -BeGreaterThan (Get-Date)
    }

    It 'resets ConsecutiveFailures on a 2xx response' {
        $state = New-ProviderThrottleState -Provider 'Graph'
        Update-ThrottleState -State $state -StatusCode 429
        Update-ThrottleState -State $state -StatusCode 429
        $state.ConsecutiveFailures | Should -Be 2
        Update-ThrottleState -State $state -StatusCode 200
        $state.ConsecutiveFailures | Should -Be 0
    }

    It 'parses integer Retry-After headers into RetryAfterUntil' {
        $state = New-ProviderThrottleState -Provider 'Graph'
        $headers = @{ 'Retry-After' = '30' }
        Update-ThrottleState -State $state -Headers $headers -StatusCode 429
        ($state.RetryAfterUntil - (Get-Date)).TotalSeconds | Should -BeGreaterThan 25
        ($state.RetryAfterUntil - (Get-Date)).TotalSeconds | Should -BeLessOrEqual 31
    }

    It 'parses HTTP-date Retry-After headers' {
        $state = New-ProviderThrottleState -Provider 'Graph'
        $future = (Get-Date).ToUniversalTime().AddSeconds(45).ToString('R')
        $headers = @{ 'Retry-After' = $future }
        Update-ThrottleState -State $state -Headers $headers -StatusCode 429
        $state.RetryAfterUntil | Should -BeGreaterThan (Get-Date)
    }

    It 'tracks the lowest remaining quota across x-ms-ratelimit-remaining-* headers' {
        $state = New-ProviderThrottleState -Provider 'Azure'
        $headers = @{
            'x-ms-ratelimit-remaining-subscription-reads' = '12000'
            'x-ms-ratelimit-remaining-tenant-reads'      = '500'
        }
        Update-ThrottleState -State $state -Headers $headers -StatusCode 200
        $state.RemainingQuota | Should -Be 500
        $state.InitialQuota   | Should -Not -BeNullOrEmpty
    }

    It 'records remaining quota from x-ratelimit-remaining (GitHub-style)' {
        $state = New-ProviderThrottleState -Provider 'GitHub'
        $headers = @{ 'x-ratelimit-remaining' = '42' }
        Update-ThrottleState -State $state -Headers $headers -StatusCode 200
        $state.RemainingQuota | Should -Be 42
        $state.InitialQuota   | Should -Be 42
    }
}

Describe 'Get-RetryAfterUntil' {

    It 'returns a future DateTime for integer seconds' {
        $until = Get-RetryAfterUntil -RetryAfter '60'
        $until | Should -Not -BeNullOrEmpty
        ($until - (Get-Date)).TotalSeconds | Should -BeGreaterThan 55
    }

    It 'returns $null for unparseable input' {
        $until = Get-RetryAfterUntil -RetryAfter 'not-a-number-or-date'
        $until | Should -BeNullOrEmpty
    }
}
