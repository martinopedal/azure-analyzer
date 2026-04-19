#Requires -Version 7.4
<#
.SYNOPSIS
    Cross-platform CI output sanitizer for issue bodies and digest output.

.DESCRIPTION
    Thin wrapper around modules/shared/Sanitize.ps1::Remove-Credentials so that
    GitHub Actions workflows (and Pester tests) share a single sanitization
    code path. Reads from -Text param when supplied, otherwise from stdin.
    Emits the redacted text on stdout. Used by ci-failure-watchdog.yml and
    ci-health-digest.yml. See `.copilot/copilot-instructions.md` -> Security
    invariants for the redaction contract.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [AllowNull()]
    [string] $Text
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSCommandPath
$SanitizeModule = Join-Path $ScriptRoot '..' 'modules' 'shared' 'Sanitize.ps1'
. $SanitizeModule

if (-not $PSBoundParameters.ContainsKey('Text')) {
    $Text = [Console]::In.ReadToEnd()
}

$result = Remove-Credentials -Text $Text
# Emit via Write-Output (not [Console]::Out) so PowerShell's success stream
# captures it for both pipeline consumers and Pester `&` invocation.
Write-Output $result
