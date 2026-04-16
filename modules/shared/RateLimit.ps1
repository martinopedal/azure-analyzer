#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ProviderThrottleState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Graph', 'ADO', 'GitHub', 'Azure')]
        [string] $Provider,
        [int] $ConcurrencyLimit
    )

    $defaults = @{
        Azure  = 8
        Graph  = 4
        ADO    = 2
        GitHub = 1
    }

    if (-not $ConcurrencyLimit -or $ConcurrencyLimit -le 0) {
        $ConcurrencyLimit = $defaults[$Provider]
    }

    return [PSCustomObject]@{
        Provider                = $Provider
        ConcurrencyLimit        = $ConcurrencyLimit
        ActiveRequests          = 0
        RetryAfterUntil         = [datetime]::MinValue
        RemainingQuota          = $null
        InitialQuota            = $null
        ConsecutiveFailures     = 0
        CircuitBreakerThreshold = 5
        CircuitOpenUntil        = [datetime]::MinValue
        RemainingQuotaByHeader  = @{}
    }
}

function Test-ShouldThrottle {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $now = Get-Date
    $delay = 0.0
    $reason = ''

    if ($State.CircuitOpenUntil -gt $now) {
        $delay = ($State.CircuitOpenUntil - $now).TotalSeconds
        $reason = 'CircuitOpen'
    } elseif ($State.RetryAfterUntil -gt $now) {
        $delay = ($State.RetryAfterUntil - $now).TotalSeconds
        $reason = 'RetryAfter'
    } elseif ($State.InitialQuota -and $State.RemainingQuota -ne $null) {
        $ratio = $State.RemainingQuota / [double]$State.InitialQuota
        if ($ratio -lt 0.1) {
            $delay = 5
            $reason = 'LowQuota'
        }
    }

    if (-not $reason -and $State.ActiveRequests -ge $State.ConcurrencyLimit) {
        $delay = 1
        $reason = 'ConcurrencyLimit'
    }

    return [PSCustomObject]@{
        ShouldThrottle = ($delay -gt 0)
        DelaySeconds   = [math]::Max(0, [math]::Round($delay, 2))
        Reason         = $reason
    }
}

function Update-ThrottleState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $State,
        [hashtable] $Headers,
        [int] $StatusCode
    )

    if ($Headers) {
        foreach ($key in $Headers.Keys) {
            if ($key -match '^(?i)x-ms-ratelimit-remaining-') {
                $value = [int]$Headers[$key]
                $State.RemainingQuotaByHeader[$key] = $value
                if (($null -eq $State.RemainingQuota) -or ($value -lt $State.RemainingQuota)) {
                    $State.RemainingQuota = $value
                }
                if (-not $State.InitialQuota) {
                    $State.InitialQuota = $value
                }
            }
        }

        foreach ($key in $Headers.Keys) {
            if ($key -match '^(?i)x-ratelimit-remaining$') {
                $value = [int]$Headers[$key]
                $State.RemainingQuota = $value
                if (-not $State.InitialQuota) {
                    $State.InitialQuota = $value
                }
                break
            }
        }

        foreach ($key in $Headers.Keys) {
            if ($key -match '^(?i)retry-after$') {
                $retryAfter = $Headers[$key]
                $retryUntil = Get-RetryAfterUntil -RetryAfter $retryAfter
                if ($retryUntil) {
                    $State.RetryAfterUntil = $retryUntil
                }
                break
            }
        }

        foreach ($key in $Headers.Keys) {
            if ($key -match '^(?i)x-ratelimit-reset$') {
                $reset = $Headers[$key]
                $epoch = 0L
                if ([long]::TryParse($reset.ToString(), [ref]$epoch)) {
                    $State.RetryAfterUntil = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime
                }
                break
            }
        }
    }

    if ($StatusCode -in 429, 403) {
        $State.ConsecutiveFailures++
    } elseif ($StatusCode -ge 200 -and $StatusCode -lt 300) {
        $State.ConsecutiveFailures = 0
    }

    if ($State.ConsecutiveFailures -ge $State.CircuitBreakerThreshold) {
        $State.CircuitOpenUntil = (Get-Date).AddSeconds(60)
    }
}

function Get-RetryAfterUntil {
    param (
        [Parameter(Mandatory)]
        [string] $RetryAfter
    )

    $seconds = 0
    if ([int]::TryParse($RetryAfter, [ref]$seconds)) {
        return (Get-Date).AddSeconds($seconds)
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($RetryAfter, [ref]$parsed)) {
        return $parsed
    }

    return $null
}
