#Requires -Version 7.0
function New-WrapperEnvelope {
    <#
    .SYNOPSIS
        Build a canonical v1 wrapper envelope for error or empty-result paths.
    .DESCRIPTION
        All 37 wrappers must return a consistent PSCustomObject envelope on ALL
        code paths (success, partial failure, skip, fatal error). This helper
        produces the canonical structure for error and empty-result returns.

        Dot-source this file to define the function without side effects.
    .PARAMETER Source
        Tool/wrapper name (e.g., 'gitleaks', 'trivy', 'maester').
    .PARAMETER Status
        One of: 'Success', 'Skipped', 'Failed'. Defaults to 'Failed'.
    .PARAMETER Message
        Human-readable status message. Pass through Remove-Credentials before
        calling if the message contains error details.
    .PARAMETER FindingErrors
        Array of FindingError objects (from New-FindingError) to attach.
        These are placed in the Errors array of the envelope.
    .EXAMPLE
        catch {
            $err = New-FindingError -Source 'wrapper:maester' `
                -Category 'MissingDependency' `
                -Reason 'Maester module not found' `
                -Remediation 'Install-Module -Name Maester'
            return New-WrapperEnvelope -Source 'maester' -Status 'Failed' `
                -Message (Remove-Credentials $_) -FindingErrors @($err)
        }
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Source,

        [ValidateSet('Success', 'Skipped', 'Failed')]
        [string] $Status = 'Failed',

        [string] $Message = '',

        [object[]] $FindingErrors = @()
    )

    return [PSCustomObject]@{
        Source        = $Source
        SchemaVersion = '1.0'
        Status        = $Status
        Message       = $Message
        Findings      = @()
        Errors        = @($FindingErrors)
    }
}
