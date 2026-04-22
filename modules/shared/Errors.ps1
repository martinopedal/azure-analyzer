# Errors.ps1 — rich, sanitized error helpers for orchestrator + wrappers.
#
# Companion to New-InstallerError / Write-InstallerError in Installer.ps1.
# Whereas InstallerError covers prerequisite-installation failures, FindingError
# covers the broader "validation / runtime / external-call" surface used by the
# orchestrator and shared modules. Both shapes guarantee:
#   - sanitized Details (Remove-Credentials applied to free-text fields)
#   - a Category enum so consumers can branch on failure class
#   - an optional Remediation string so users see a next action, never a bare
#     "Failed to X."
#
# Use Format-FindingErrorMessage when you need to `throw` a string-style
# exception (the most common pattern in PowerShell). Use Write-FindingError
# when emitting a warning/log line is enough.

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

$script:FindingErrorCategories = @(
    'InvalidParameter',
    'MissingDependency',
    'AuthenticationFailed',
    'AuthorizationFailed',
    'NotFound',
    'TransientFailure',
    'TimeoutExceeded',
    'ConfigurationError',
    'IOFailure',
    'UnexpectedFailure'
)

function New-FindingError {
    <#
    .SYNOPSIS
        Build a sanitized, structured error describing an orchestrator or
        wrapper failure.
    .DESCRIPTION
        Returns a PSCustomObject with Source, Category, Reason, Remediation,
        and Details. All free-text fields pass through Remove-Credentials so
        the object is safe to log or serialize.
    .PARAMETER Source
        The component raising the error (e.g. 'orchestrator',
        'wrapper:azqr', 'shared:RemoteClone').
    .PARAMETER Category
        One of the FindingErrorCategories enum values.
    .PARAMETER Reason
        Short human-readable explanation of what failed.
    .PARAMETER Remediation
        Concrete next action the user should take. Strongly encouraged.
    .PARAMETER Details
        Free-text additional context (stderr snippets, exception messages).
        Will be sanitized before being attached.
    #>
    param (
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Reason,
        [string] $Remediation,
        [string] $Details
    )
    if ($Category -notin $script:FindingErrorCategories) {
        $valid = $script:FindingErrorCategories -join ', '
        throw "New-FindingError: invalid Category '$Category'. Valid values: $valid"
    }
    return [PSCustomObject]@{
        Source       = $Source
        Category     = $Category
        Reason       = Remove-Credentials ([string]$Reason)
        Remediation  = Remove-Credentials ([string]$Remediation)
        Details      = Remove-Credentials ([string]$Details)
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Format-FindingErrorMessage {
    <#
    .SYNOPSIS
        Render a FindingError object as a single-line message suitable for
        `throw` or Write-Warning.
    .EXAMPLE
        throw (Format-FindingErrorMessage (New-FindingError -Source 'orchestrator' `
            -Category 'InvalidParameter' -Reason '-Foo and -Bar are mutually exclusive.' `
            -Remediation 'Pass only one of -Foo or -Bar.'))
    #>
    param ([Parameter(Mandatory)] $FindingError)
    $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
    if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
    return $line
}

function Write-FindingError {
    <#
    .SYNOPSIS
        Emit a FindingError as a Write-Warning (with Details routed through
        Write-Verbose so they don't pollute warning output).
    #>
    param ([Parameter(Mandatory)] $FindingError)
    Write-Warning (Format-FindingErrorMessage $FindingError)
    if ($FindingError.Details) { Write-Verbose $FindingError.Details }
}
