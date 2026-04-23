#Requires -Version 7.4
<#
.SYNOPSIS
    Thin correlator wrapper for manifest dispatch.
.DESCRIPTION
    Keeps `identity-correlator` aligned with the standard Invoke-* wrapper shape
    while delegating all correlation logic to modules/shared/IdentityCorrelator.ps1.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }

try {
    . "$PSScriptRoot\shared\IdentityCorrelator.ps1"
} catch {
    Write-Warning "IdentityCorrelator failed: $_"
    return New-WrapperEnvelope -Source 'identity-correlator' -Status 'Failed' -Message "$_"
}
