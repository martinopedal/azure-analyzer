#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-WithRetry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,
        
        # New-style params
        [Nullable[int]] $MaxAttempts,

        # Legacy param: retries after first try (total attempts = MaxRetries + 1)
        [Nullable[int]] $MaxRetries,

        [Alias('BaseDelaySec')]
        [Nullable[int]] $InitialDelaySeconds,

        [Alias('MaxDelaySec')]
        [Nullable[int]] $MaxDelaySeconds,
        [string[]] $TransientMessagePatterns = @(
            '\b429\b', '\b503\b', '\b504\b', '\b408\b',
            'throttl', 'rate limit', 'too many requests',
            'timed out', 'timeout', 'service unavailable',
            'temporarily unavailable', 'connection reset', 'temporary failure',
            'could not resolve host', 'network is unreachable', 'tls handshake',
            '\beof\b', 'unexpected end', 'connection refused', 'broken pipe',
            'connection closed', 'no such host', 'i/o timeout'
        )
    )

    # Normalize params. MaxRetries (legacy) means "retries after first try" (total = MaxRetries+1).
    # MaxAttempts (new) means "total attempts including first".
    $hasMaxAttempts = $PSBoundParameters.ContainsKey('MaxAttempts')
    $hasMaxRetries = $PSBoundParameters.ContainsKey('MaxRetries')
    if ($hasMaxAttempts -and $hasMaxRetries) {
        throw [System.ArgumentException]::new('Use either -MaxAttempts or legacy -MaxRetries, not both.')
    }
    if ($hasMaxRetries) {
        $MaxAttempts = [int]$MaxRetries + 1
    } elseif (-not $hasMaxAttempts) {
        $MaxAttempts = 4   # default: 1 try + 3 retries
    }
    $baseDelay = if ($null -ne $InitialDelaySeconds) { [int]$InitialDelaySeconds } else { 2 }
    $maxDelay  = if ($null -ne $MaxDelaySeconds) { [int]$MaxDelaySeconds } else { 60 }

    $retryableCategories = @('Throttled', 'Timeout', 'ProviderError', 'ServiceUnavailable')

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Verbose "Invoke-WithRetry: Attempt $attempt of $MaxAttempts"
        try {
            return & $ScriptBlock
        } catch {
            $err = $_
            $category = Get-ErrorCategory -ErrorRecord $err
            $isRetryable = ($retryableCategories -contains $category)

            # HTTP status code check via Response.StatusCode
            $statusCode = Get-HttpStatusCode -ErrorRecord $err
            if (-not $isRetryable -and $statusCode -in 408, 429, 503, 504) {
                $isRetryable = $true
            }

            if (-not $isRetryable) {
                $msg = ([string]$err.Exception?.Message).ToLowerInvariant()
                foreach ($pat in $TransientMessagePatterns) {
                    if ($msg -match $pat) { $isRetryable = $true; break }
                }
            }

            if (-not $isRetryable) {
                $sanitized = if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
                    Remove-Credentials ([string]$err.Exception.Message)
                } else { [string]$err.Exception.Message }
                $message = "Non-retryable error category '$category'. The request failed and will not be retried. Action: verify credentials, inputs, or permissions before retrying. Details: $sanitized"
                throw [System.Exception]::new($message, $err.Exception)
            }

            if ($attempt -ge $MaxAttempts) {
                $sanitized = if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
                    Remove-Credentials ([string]$err.Exception.Message)
                } else { [string]$err.Exception.Message }
                $message = "Retry attempts exhausted after $MaxAttempts tries. Last category '$category'. Details: $sanitized. Action: wait and retry, or increase MaxAttempts/InitialDelaySeconds."
                throw [System.Exception]::new($message, $err.Exception)
            }

            # Honor Retry-After header if present and parseable
            $retryAfter = Get-RetryAfterSeconds -ErrorRecord $err
            $delay = if ($retryAfter -gt 0) {
                $retryAfter
            } else {
                Get-JitteredDelay -RetryIndex ($attempt - 1) -BaseDelaySec $baseDelay -MaxDelaySec $maxDelay
            }

            Write-Verbose "Invoke-WithRetry: retryable '$category' (status=$statusCode), sleeping $delay s before next attempt"
            Start-Sleep -Seconds ([math]::Max(0, [double]$delay))
        }
    }
}

function Get-ErrorCategory {
    param ([Parameter(Mandatory)][object] $ErrorRecord)

    $candidates = @(
        $ErrorRecord.Exception?.PSObject.Properties['Category']?.Value,
        $ErrorRecord.PSObject.Properties['Category']?.Value,
        $ErrorRecord.PSObject.Properties['ErrorCategory']?.Value,
        $ErrorRecord.CategoryInfo?.Category
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.ToString()
        }
    }
    return 'Unknown'
}

function Get-HttpStatusCode {
    param ([Parameter(Mandatory)][object] $ErrorRecord)

    $response = $ErrorRecord.Exception?.PSObject.Properties['Response']?.Value
    if ($null -eq $response) { return 0 }
    $status = $response.PSObject.Properties['StatusCode']?.Value
    if ($null -eq $status) { return 0 }
    try { return [int]$status } catch { return 0 }
}

function Get-RetryAfterSeconds {
    param ([Parameter(Mandatory)][object] $ErrorRecord)

    $response = $ErrorRecord.Exception?.PSObject.Properties['Response']?.Value
    if ($null -eq $response) { return 0 }
    $headers = $response.PSObject.Properties['Headers']?.Value
    if ($null -eq $headers) { return 0 }

    $raw = $null
    try {
        if ($headers -is [System.Collections.IDictionary]) {
            $raw = $headers['Retry-After']
        } else {
            $raw = $headers.'Retry-After'
        }
    } catch { return 0 }

    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return 0 }

    # Try integer seconds first
    [int]$seconds = 0
    if ([int]::TryParse([string]$raw, [ref]$seconds) -and $seconds -ge 0) {
        return $seconds
    }

    # Fall back to HTTP-date (RFC 7231)
    try {
        $target = [datetime]::Parse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $delta = [int][math]::Max(0, ($target.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds)
        return $delta
    } catch { return 0 }
}

function Get-JitteredDelay {
    param (
        [int] $RetryIndex,
        [int] $BaseDelaySec,
        [int] $MaxDelaySec
    )

    $backoff = [math]::Min($MaxDelaySec, $BaseDelaySec * [math]::Pow(2, $RetryIndex))
    if ($backoff -le 0) {
        return 0
    }

    # Full jitter: random delay between 0 and the exponential backoff cap.
    return [math]::Round((Get-Random -Minimum 0.0 -Maximum ([double]$backoff)), 2)
}
