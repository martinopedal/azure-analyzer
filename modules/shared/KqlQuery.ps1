#Requires -Version 7.4
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-LogAnalyticsQuery {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        [ValidateRange(30, 1800)]
        [int] $TimeoutSeconds = 300
    )

    if (-not (Get-Module -ListAvailable -Name Az.OperationalInsights)) {
        throw 'Az.OperationalInsights module not installed. Run Install-Module Az.OperationalInsights -Scope CurrentUser'
    }

    Import-Module Az.OperationalInsights -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    $invokeQuery = {
        Invoke-AzOperationalInsightsQuery -WorkspaceId $using:WorkspaceId -Query $using:Query -Wait $using:TimeoutSeconds -ErrorAction Stop
    }

    return Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 20 -ScriptBlock $invokeQuery
}
