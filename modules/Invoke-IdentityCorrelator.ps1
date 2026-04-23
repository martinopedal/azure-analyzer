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

. "$PSScriptRoot\shared\IdentityCorrelator.ps1"
