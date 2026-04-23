#Requires -Version 7.4

Set-StrictMode -Version Latest

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    $sanitizePath = Join-Path $PSScriptRoot 'Sanitize.ps1'
    if (Test-Path $sanitizePath) { . $sanitizePath }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

function Test-MandatoryParamInteractive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $ci = [string]$env:CI
    if ($ci -imatch '^(true|1|yes|on)$') { return $false }

    try {
        if (-not [Environment]::UserInteractive) { return $false }
    } catch { return $false }

    try {
        if ([Console]::IsInputRedirected) { return $false }
    } catch {} # best-effort: stdin not a console (e.g., service host); treat as non-interactive

    return $true
}

function Read-MandatoryScannerParam {
    <#
    .SYNOPSIS
        Resolve a mandatory scanner parameter via env-var fallback or interactive prompt.
    .DESCRIPTION
        Resolution order:
          1. EnvVarFallback (when set and the env var is non-empty).
          2. Read-Host prompt (only when running interactively and not in CI).
          3. $null with a Write-Warning advising the user how to provide the value.
        Output is sanitized via Remove-Credentials before logging.
    .PARAMETER ScannerName
        Logical scanner identifier (e.g. 'gitleaks', 'azqr'). Used in prompt and warning text.
    .PARAMETER ParamName
        The orchestrator parameter name (e.g. 'SubscriptionId', 'AdoOrg').
    .PARAMETER EnvVarFallback
        Optional environment variable consulted before prompting (e.g. 'AZURE_SUBSCRIPTION_ID').
    .PARAMETER Example
        Optional example value displayed in the prompt to help the user.
    .OUTPUTS
        [string] resolved value, or $null when unresolved in a non-interactive session.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ScannerName,

        [Parameter(Mandatory)]
        [string] $ParamName,

        [string] $EnvVarFallback,

        [string] $Example
    )

    if (-not [string]::IsNullOrWhiteSpace($EnvVarFallback)) {
        $envValue = [Environment]::GetEnvironmentVariable($EnvVarFallback)
        if (-not [string]::IsNullOrWhiteSpace([string]$envValue)) {
            Write-Verbose (Remove-Credentials -Text "Resolved -$ParamName for scanner '$ScannerName' from env:$EnvVarFallback")
            return [string]$envValue
        }
    }

    if (-not (Test-MandatoryParamInteractive)) {
        $remediation = "Skipping scanner '$ScannerName': mandatory parameter -$ParamName was not supplied."
        if (-not [string]::IsNullOrWhiteSpace($EnvVarFallback)) {
            $remediation += " Set env:$EnvVarFallback or pass -$ParamName explicitly."
        } else {
            $remediation += " Pass -$ParamName explicitly."
        }
        Write-Warning (Remove-Credentials -Text $remediation)
        return $null
    }

    $promptText = "Enter -$ParamName for scanner '$ScannerName'"
    if (-not [string]::IsNullOrWhiteSpace($Example)) {
        $promptText = "$promptText (example: $Example)"
    }
    $value = Read-Host -Prompt $promptText
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        Write-Warning (Remove-Credentials -Text "Skipping scanner '$ScannerName': -$ParamName was not provided.")
        return $null
    }
    return [string]$value
}
