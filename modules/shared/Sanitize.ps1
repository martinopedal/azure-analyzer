#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-Credentials {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $sanitized = $Text
    $rules = @(
        @{ Pattern = 'ghp_[A-Za-z0-9]{36}'; Replacement = '[GITHUB-PAT-REDACTED]' },
        @{ Pattern = 'gho_[A-Za-z0-9]{36}'; Replacement = '[GITHUB-OAUTH-REDACTED]' },
        @{ Pattern = 'ghs_[A-Za-z0-9]{36}'; Replacement = '[GITHUB-TOKEN-REDACTED]' },
        @{ Pattern = 'ghr_[A-Za-z0-9]{36}'; Replacement = '[GITHUB-REFRESH-REDACTED]' },
        @{ Pattern = 'github_pat_[A-Za-z0-9_]{82}'; Replacement = '[GITHUB-PAT-REDACTED]' },
        @{ Pattern = '(?im)Authorization:\s*Basic\s+[A-Za-z0-9+/=]{16,}'; Replacement = 'Authorization: [ADO-PAT-REDACTED]' },
        @{ Pattern = '(?im)Authorization:\s*(Bearer|Basic)\s+\S+'; Replacement = 'Authorization: [REDACTED]' },
        @{ Pattern = '(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*'; Replacement = 'Bearer [REDACTED]' },
        @{ Pattern = '(?i)\b(AccountKey|SharedAccessKey|Password)=[^;]+'; Replacement = '$1=[REDACTED]' },
        @{ Pattern = '(?i)"(password|accountkey|sharedaccesskey|client_secret)"\s*:\s*"[^"]+"'; Replacement = '"$1":"[REDACTED]"' },
        @{ Pattern = '(?im)(^|,)\s*(password|accountkey|sharedaccesskey|client_secret)\s*,\s*[^,\r\n]+'; Replacement = '$1$2,[REDACTED]' },
        @{ Pattern = '(?i)\bsig=[A-Za-z0-9%+/=]{10,}'; Replacement = 'sig=[REDACTED]' },
        @{ Pattern = '(?i)\bclient_secret=[^&\s]+'; Replacement = 'client_secret=[REDACTED]' },
        @{ Pattern = '(?i)\bSharedAccessSignature=[^;]+'; Replacement = 'SharedAccessSignature=[REDACTED]' }
    )

    foreach ($rule in $rules) {
        $sanitized = [regex]::Replace($sanitized, $rule.Pattern, $rule.Replacement)
    }

    return $sanitized
}
