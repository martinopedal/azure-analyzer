#Requires -Version 7.4
Set-StrictMode -Version Latest

function ConvertTo-MaskedId {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [object] $Id,
        [string] $Type,
        [switch] $IncludeSensitiveDetails
    )

    if ($IncludeSensitiveDetails) {
        return $Id
    }

    if ($null -eq $Id) {
        return $null
    }

    $idText = $Id.ToString()
    if ([string]::IsNullOrWhiteSpace($idText)) {
        return $idText
    }

    switch -Regex ($Type) {
        '^(?i)tenantid$' {
            return '[tenant-id]'
        }
        '^(?i)(appid|objectid)$' {
            return ConvertTo-MaskedGuid -Value $idText
        }
        default {
            return $idText
        }
    }
}

function ConvertTo-MaskedGuid {
    param (
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value.Length -le 8) {
        return ('*' * $Value.Length)
    }

    $chars = $Value.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        if ($i -lt 4 -or $i -ge ($chars.Length - 4)) {
            continue
        }
        if ($chars[$i] -ne '-') {
            $chars[$i] = '*'
        }
    }

    return -join $chars
}
