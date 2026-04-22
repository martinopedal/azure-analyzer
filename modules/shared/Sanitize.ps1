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
        # JWT (header.payload.signature, base64url, each segment >=10 chars)
        @{ Pattern = '\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b'; Replacement = '[JWT-REDACTED]' },
        # OpenAI-style secrets (sk-... and sk-proj-...)
        @{ Pattern = '\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}'; Replacement = '[OPENAI-KEY-REDACTED]' },
        # Slack bot/user/app tokens
        @{ Pattern = '\bxox[baprs]-[A-Za-z0-9-]{10,}'; Replacement = '[SLACK-TOKEN-REDACTED]' },
        # Azure OpenAI / generic API key env-var style
        @{ Pattern = '(?i)\bAZURE_OPENAI_API_KEY\s*=\s*[^\s;,&"'']+'; Replacement = 'AZURE_OPENAI_API_KEY=[REDACTED]' },
        @{ Pattern = '(?i)\b(AccountKey|SharedAccessKey|Password)=[^;]+'; Replacement = '$1=[REDACTED]' },
        # SAS query params
        @{ Pattern = '(?i)([?&])sig=[A-Za-z0-9%+/=]{10,}'; Replacement = '$1sig=[REDACTED]' },
        @{ Pattern = '(?i)([?&])sv=[0-9]{4}-[0-9]{2}-[0-9]{2}'; Replacement = '$1sv=[REDACTED]' },
        @{ Pattern = '(?i)\bsig=[A-Za-z0-9%+/=]{10,}'; Replacement = 'sig=[REDACTED]' },
        @{ Pattern = '(?i)\bclient_secret=[^&\s]+'; Replacement = 'client_secret=[REDACTED]' },
        @{ Pattern = '(?i)\bSharedAccessSignature=[^;]+'; Replacement = 'SharedAccessSignature=[REDACTED]' }
    )

    foreach ($rule in $rules) {
        $sanitized = [regex]::Replace($sanitized, $rule.Pattern, $rule.Replacement)
    }

    return $sanitized
}
