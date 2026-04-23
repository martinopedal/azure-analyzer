#Requires -Version 7.0
<#
.SYNOPSIS
    Helper to invoke a wrapper scriptblock and capture host warnings (#770).

.DESCRIPTION
    Wrapper smoke tests historically only inspected the return object, which
    let WARNING: lines slip through unnoticed (see #768 for two real examples).

    Invoke-WrapperWithHostCapture runs a wrapper scriptblock with stream-3
    (Warning) and stream-6 (Information) redirected into a buffer, returning
    a hashtable with the unwrapped Result and the captured Warnings list.

    Tests then assert:
      - $capture.Result.Status -eq 'Success'
      - $capture.Warnings is empty (unless the test is tagged AllowsWarning)
#>

Set-StrictMode -Version Latest

function Invoke-WrapperWithHostCapture {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock
    )

    $warningBuffer = [System.Collections.Generic.List[string]]::new()
    $warningLikeInfoPattern = '^(?i:(WARNING:|##\[warning\]|Notice:))'
    $result = $null
    try {
        # 3>&1 and 6>&1 redirect warning/information streams into success so we
        # can sift warning records and warning-like information markers without
        # re-emitting them to the host (which would still pollute the Pester
        # transcript). The scriptblock's actual return value is the last
        # non-warning-like emission.
        $merged = & {
            & $ScriptBlock
        } 3>&1 6>&1

        foreach ($item in @($merged)) {
            if ($item -is [System.Management.Automation.WarningRecord]) {
                $warningBuffer.Add([string]$item.Message)
            } elseif ($item -is [System.Management.Automation.InformationRecord]) {
                $message = [string]$item.MessageData
                if ($message -match $warningLikeInfoPattern) {
                    $warningBuffer.Add($message)
                }
            } else {
                $result = $item
            }
        }
    } catch {
        return @{
            Result   = $null
            Warnings = $warningBuffer.ToArray()
            Error    = $_
        }
    }

    return @{
        Result   = $result
        Warnings = $warningBuffer.ToArray()
        Error    = $null
    }
}
