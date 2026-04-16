#Requires -Version 7.4
Set-StrictMode -Version Latest

function Invoke-WithRetry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,
        [int] $MaxRetries = 3,
        [int] $BaseDelaySec = 2,
        [int] $MaxDelaySec = 60
    )

    $retryable = @('Throttled', 'Timeout', 'ProviderError', 'ServiceUnavailable')
    $totalAttempts = $MaxRetries + 1

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            $category = Get-ErrorCategory -ErrorRecord $_
            $normalized = $category.ToString()

            if ($retryable -notcontains $normalized) {
                $message = "Non-retryable error category '$normalized'. The request failed and will not be retried. Action: verify credentials, inputs, or permissions before retrying."
                throw [System.Exception]::new($message, $_.Exception)
            }

            if ($attempt -ge $MaxRetries) {
                $message = "Retry attempts exhausted after $totalAttempts tries. Last category '$normalized'. Action: wait and retry, or increase MaxRetries/BaseDelaySec."
                throw [System.Exception]::new($message, $_.Exception)
            }

            $delay = Get-JitteredDelay -RetryIndex $attempt -BaseDelaySec $BaseDelaySec -MaxDelaySec $MaxDelaySec
            if ($delay -gt 0) {
                Start-Sleep -Seconds $delay
            }
        }
    }
}

function Get-ErrorCategory {
    param (
        [Parameter(Mandatory)]
        [object] $ErrorRecord
    )

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

function Get-JitteredDelay {
    param (
        [int] $RetryIndex,
        [int] $BaseDelaySec,
        [int] $MaxDelaySec
    )

    $baseDelay = [math]::Min($MaxDelaySec, $BaseDelaySec * [math]::Pow(2, $RetryIndex))
    if ($baseDelay -le 0) {
        return 0
    }

    $bytes = New-Object byte[] 4
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $rand = [BitConverter]::ToUInt32($bytes, 0) / [uint32]::MaxValue
    $delta = ($rand * 0.5) - 0.25
    $jittered = $baseDelay * (1 + $delta)

    return [math]::Min($MaxDelaySec, [math]::Max(0, [math]::Round($jittered, 2)))
}
