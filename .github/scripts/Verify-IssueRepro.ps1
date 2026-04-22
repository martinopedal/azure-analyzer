#Requires -Version 7.4
<#
.SYNOPSIS
Parse and execute the ## Repro block from a GitHub issue body.

.DESCRIPTION
Helper for .github/workflows/issue-resolution-verify.yml (Praxis contract).
Exposes three pure functions so they can be unit-tested in Pester without
touching the network or the GitHub Actions runtime:

  - Get-IssueReproBlock : parse the issue body, return $null or a hashtable
                         @{ Type; Command; Expect }
  - Invoke-IssueRepro   : execute the parsed block under a 300s timeout,
                         return @{ Status; Output; ExitCode }
  - Format-SanitizedTail: strip secrets from output and return the last N lines

Repro block format (inside ## Repro or ## Reproduction heading, fenced):
  pester: <FullNameFilter pattern>
  shell:  <single-line pwsh command>
  gh:     <single-line gh CLI call>
  expect: <optional regex matched against gh stdout>
  manual: <free text - skipped, requires manual verification>
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Inlined sanitization rules - kept in lockstep with modules/shared/Sanitize.ps1.
# If you update the rules there, mirror them here AND in the test fixture.
$script:PraxisSanitizeRules = @(
    @{ Pattern = 'ghp_[A-Za-z0-9]{36}';                                 Replacement = '[GITHUB-PAT-REDACTED]' },
    @{ Pattern = 'gho_[A-Za-z0-9]{36}';                                 Replacement = '[GITHUB-OAUTH-REDACTED]' },
    @{ Pattern = 'ghs_[A-Za-z0-9]{36}';                                 Replacement = '[GITHUB-TOKEN-REDACTED]' },
    @{ Pattern = 'ghr_[A-Za-z0-9]{36}';                                 Replacement = '[GITHUB-REFRESH-REDACTED]' },
    @{ Pattern = 'github_pat_[A-Za-z0-9_]{82}';                         Replacement = '[GITHUB-PAT-REDACTED]' },
    @{ Pattern = '(?im)Authorization:\s*(Bearer|Basic)\s+\S+';          Replacement = 'Authorization: [REDACTED]' },
    @{ Pattern = '(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*';                Replacement = 'Bearer [REDACTED]' },
    @{ Pattern = '(?i)\b(AccountKey|SharedAccessKey|Password)=[^;]+';   Replacement = '$1=[REDACTED]' },
    @{ Pattern = '(?i)\bsig=[A-Za-z0-9%+/=]{10,}';                      Replacement = 'sig=[REDACTED]' },
    @{ Pattern = '(?i)\bclient_secret=[^&\s]+';                         Replacement = 'client_secret=[REDACTED]' },
    @{ Pattern = '(?i)\bSharedAccessSignature=[^;]+';                   Replacement = 'SharedAccessSignature=[REDACTED]' }
)

function Remove-PraxisCredentials {
    [CmdletBinding()]
    param([AllowNull()][string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $sanitized = $Text
    foreach ($rule in $script:PraxisSanitizeRules) {
        $sanitized = [regex]::Replace($sanitized, $rule.Pattern, $rule.Replacement)
    }
    return $sanitized
}

function Get-IssueReproBlock {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }

    $normalized = $Body -replace "`r`n", "`n"

    $headingPattern = '(?im)^##\s+Repro(?:duction)?\s*$'
    $headingMatch = [regex]::Match($normalized, $headingPattern)
    if (-not $headingMatch.Success) { return $null }

    $afterHeading = $normalized.Substring($headingMatch.Index + $headingMatch.Length)
    $fencePattern = '(?s)```[A-Za-z0-9_+-]*\r?\n(.*?)\r?\n```'
    $fenceMatch = [regex]::Match($afterHeading, $fencePattern)
    if (-not $fenceMatch.Success) { return $null }

    $blockBody = $fenceMatch.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($blockBody)) { return $null }

    $lines = @($blockBody -split "`n" | ForEach-Object { $_.TrimEnd() })
    $first = $lines[0]

    $typeMatch = [regex]::Match($first, '^(pester|shell|gh|manual)\s*:\s*(.*)$', 'IgnoreCase')
    if (-not $typeMatch.Success) { return $null }

    $type = $typeMatch.Groups[1].Value.ToLowerInvariant()
    $command = $typeMatch.Groups[2].Value.Trim()

    $expect = $null
    if ($type -eq 'gh' -and $lines.Count -ge 2) {
        $expectMatch = [regex]::Match($lines[1], '^expect\s*:\s*(.*)$', 'IgnoreCase')
        if ($expectMatch.Success) { $expect = $expectMatch.Groups[1].Value.Trim() }
    }

    return @{
        Type    = $type
        Command = $command
        Expect  = $expect
    }
}

function Invoke-IssueRepro {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Repro,
        [int] $TimeoutSeconds = 300
    )

    if ($Repro.Type -eq 'manual') {
        return @{ Status = 'MANUAL'; Output = 'manual verification required'; ExitCode = 0 }
    }

    if ([string]::IsNullOrWhiteSpace($Repro.Command)) {
        return @{ Status = 'FAIL'; Output = "empty command for type '$($Repro.Type)'"; ExitCode = 1 }
    }

    switch ($Repro.Type) {
        'pester' {
            $result = $null
            try {
                Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
                $cfg = New-PesterConfiguration
                $cfg.Run.Path = '.\tests'
                $cfg.Run.PassThru = $true
                $cfg.Filter.FullName = $Repro.Command
                $cfg.Output.Verbosity = 'Detailed'
                $result = Invoke-Pester -Configuration $cfg
            } catch {
                return @{ Status = 'FAIL'; Output = "pester invocation threw: $($_.Exception.Message)"; ExitCode = 1 }
            }
            $passed = ($result.FailedCount -eq 0) -and ($result.PassedCount -ge 1)
            $output = "Pester: Passed=$($result.PassedCount) Failed=$($result.FailedCount) Skipped=$($result.SkippedCount) Pattern='$($Repro.Command)'"
            return @{ Status = ($passed ? 'PASS' : 'FAIL'); Output = $output; ExitCode = ($passed ? 0 : 1) }
        }

        'shell' {
            $stdoutPath = [System.IO.Path]::GetTempFileName()
            $stderrPath = [System.IO.Path]::GetTempFileName()
            try {
                $proc = Start-Process pwsh `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Repro.Command) `
                    -RedirectStandardOutput $stdoutPath `
                    -RedirectStandardError  $stderrPath `
                    -PassThru -NoNewWindow
                if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                    $proc.Kill($true)
                    return @{ Status = 'FAIL'; Output = "TIMEOUT after ${TimeoutSeconds}s: $($Repro.Command)"; ExitCode = 124 }
                }
                $exitCode = $proc.ExitCode
                $combined = (Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue) + "`n" +
                            (Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue)
                return @{ Status = ($exitCode -eq 0 ? 'PASS' : 'FAIL'); Output = $combined; ExitCode = $exitCode }
            } finally {
                Remove-Item $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
            }
        }

        'gh' {
            $stdoutPath = [System.IO.Path]::GetTempFileName()
            $stderrPath = [System.IO.Path]::GetTempFileName()
            try {
                $cmd = $Repro.Command
                if ($cmd -notmatch '^\s*gh\b') { $cmd = 'gh ' + $cmd }
                $proc = Start-Process pwsh `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) `
                    -RedirectStandardOutput $stdoutPath `
                    -RedirectStandardError  $stderrPath `
                    -PassThru -NoNewWindow
                if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                    $proc.Kill($true)
                    return @{ Status = 'FAIL'; Output = "TIMEOUT after ${TimeoutSeconds}s: $cmd"; ExitCode = 124 }
                }
                $exitCode = $proc.ExitCode
                $stdout = (Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue) ?? ''
                $stderr = (Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue) ?? ''
                $combined = "$stdout`n$stderr"
                if ($exitCode -ne 0) {
                    return @{ Status = 'FAIL'; Output = $combined; ExitCode = $exitCode }
                }
                if ($Repro.Expect) {
                    if ($stdout -notmatch $Repro.Expect) {
                        return @{ Status = 'FAIL'; Output = "stdout did not match expect regex '$($Repro.Expect)'.`n$combined"; ExitCode = 1 }
                    }
                }
                return @{ Status = 'PASS'; Output = $combined; ExitCode = 0 }
            } finally {
                Remove-Item $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
            }
        }

        default {
            return @{ Status = 'FAIL'; Output = "unknown repro type '$($Repro.Type)'"; ExitCode = 1 }
        }
    }
}

function Format-SanitizedTail {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string] $Output,
        [int] $Lines = 50
    )
    if ([string]::IsNullOrEmpty($Output)) { return '' }
    $sanitized = Remove-PraxisCredentials -Text $Output
    $split = $sanitized -split "`r?`n"
    $tail = if ($split.Count -le $Lines) { $split } else { $split[-$Lines..-1] }
    return ($tail -join "`n")
}
