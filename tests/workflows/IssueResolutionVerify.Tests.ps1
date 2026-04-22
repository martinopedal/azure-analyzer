#Requires -Version 7.4
<#
.SYNOPSIS
Tests for .github/scripts/Verify-IssueRepro.ps1 (Praxis verification helper).

.DESCRIPTION
Asserts the contract used by .github/workflows/issue-resolution-verify.yml:
  - Each repro type (pester / shell / gh / manual) parses correctly.
  - Missing block returns $null (fail-soft path in the workflow).
  - Sanitization strips known secret patterns from output before posting.
  - Tail extraction caps output at the requested line count.
  - Workflow YAML pins SHAs, declares the right perms/triggers, retry-wraps net calls.
#>

BeforeAll {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:HelperPath = Join-Path $script:RepoRoot '.github' 'scripts' 'Verify-IssueRepro.ps1'
    if (-not (Test-Path $script:HelperPath)) {
        throw "Helper script not found at $script:HelperPath"
    }
    . $script:HelperPath
}

Describe 'Get-IssueReproBlock - parser' {
    It 'returns $null when body is empty' {
        Get-IssueReproBlock -Body '' | Should -BeNullOrEmpty
    }

    It 'returns $null when body has no ## Repro heading' {
        $body = "## Summary`n`nbroken`n`n## Steps`n1. do stuff"
        Get-IssueReproBlock -Body $body | Should -BeNullOrEmpty
    }

    It 'returns $null when ## Repro heading exists but has no fenced block' {
        $body = "## Repro`n`nrun the thing manually"
        Get-IssueReproBlock -Body $body | Should -BeNullOrEmpty
    }

    It 'parses a pester repro' {
        $body = "## Repro`n`n" + '```' + "`npester: New-HtmlReport.* zero findings`n" + '```'
        $r = Get-IssueReproBlock -Body $body
        $r | Should -Not -BeNullOrEmpty
        $r.Type    | Should -Be 'pester'
        $r.Command | Should -Be 'New-HtmlReport.* zero findings'
        $r.Expect  | Should -BeNullOrEmpty
    }

    It 'parses a shell repro' {
        $body = "## Repro`n`n" + '```' + "`nshell: pwsh -NoProfile -File .\Invoke-AzureAnalyzer.ps1 -DryRun`n" + '```'
        $r = Get-IssueReproBlock -Body $body
        $r.Type    | Should -Be 'shell'
        $r.Command | Should -Be 'pwsh -NoProfile -File .\Invoke-AzureAnalyzer.ps1 -DryRun'
    }

    It 'parses a gh repro with expect regex' {
        $body = "## Repro`n`n" + '```' + "`ngh: gh workflow view ci.yml --repo martinopedal/azure-analyzer`nexpect: Analyze \(actions\)`n" + '```'
        $r = Get-IssueReproBlock -Body $body
        $r.Type    | Should -Be 'gh'
        $r.Command | Should -Be 'gh workflow view ci.yml --repo martinopedal/azure-analyzer'
        $r.Expect  | Should -Be 'Analyze \(actions\)'
    }

    It 'parses a manual repro' {
        $body = "## Repro`n`n" + '```' + "`nmanual: Open the rendered HTML and check dark mode persists.`n" + '```'
        $r = Get-IssueReproBlock -Body $body
        $r.Type    | Should -Be 'manual'
        $r.Command | Should -Match 'dark mode'
    }

    It 'accepts the alternate ## Reproduction heading' {
        $body = "## Reproduction`n`n" + '```' + "`nshell: echo ok`n" + '```'
        $r = Get-IssueReproBlock -Body $body
        $r.Type    | Should -Be 'shell'
        $r.Command | Should -Be 'echo ok'
    }

    It 'is case-insensitive on the type token' {
        $body = "## Repro`n`n" + '```' + "`nPESTER: SomePattern`n" + '```'
        $r = Get-IssueReproBlock -Body $body
        $r.Type | Should -Be 'pester'
    }

    It 'tolerates CRLF line endings' {
        $body = "## Repro`r`n`r`n" + '```' + "`r`nshell: echo crlf`r`n" + '```' + "`r`n"
        $r = Get-IssueReproBlock -Body $body
        $r.Type    | Should -Be 'shell'
        $r.Command | Should -Be 'echo crlf'
    }

    It 'returns $null when the first fenced line is not a known type' {
        $body = "## Repro`n`n" + '```' + "`nunknown: do something`n" + '```'
        Get-IssueReproBlock -Body $body | Should -BeNullOrEmpty
    }
}

Describe 'Format-SanitizedTail - sanitization + tail' {
    It 'returns empty string for null input' {
        Format-SanitizedTail -Output $null | Should -Be ''
    }

    It 'returns empty string for empty input' {
        Format-SanitizedTail -Output '' | Should -Be ''
    }

    It 'redacts ghp_ tokens' {
        $secret = 'ghp_' + ('A' * 36)
        $out = Format-SanitizedTail -Output "leaked: $secret here"
        $out | Should -Not -Match 'ghp_AAAA'
        $out | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'redacts gho_ tokens' {
        $secret = 'gho_' + ('B' * 36)
        $out = Format-SanitizedTail -Output "value=$secret"
        $out | Should -Match '\[GITHUB-OAUTH-REDACTED\]'
        $out | Should -Not -Match 'gho_BBBB'
    }

    It 'redacts Authorization Bearer headers' {
        $out = Format-SanitizedTail -Output 'Authorization: Bearer abc.def.ghi'
        $out | Should -Match 'Authorization: \[REDACTED\]'
    }

    It 'redacts AccountKey in connection strings' {
        $out = Format-SanitizedTail -Output 'DefaultEndpointsProtocol=https;AccountKey=verysecret;EndpointSuffix=core.windows.net'
        $out | Should -Match 'AccountKey=\[REDACTED\]'
        $out | Should -Not -Match 'verysecret'
    }

    It 'caps output at the requested line count' {
        $lines = 1..100 | ForEach-Object { "line $_" }
        $out = Format-SanitizedTail -Output ($lines -join "`n") -Lines 10
        $split = $out -split "`n"
        $split.Count | Should -Be 10
        $split[0]    | Should -Be 'line 91'
        $split[-1]   | Should -Be 'line 100'
    }

    It 'returns full text when shorter than the line cap' {
        $out = Format-SanitizedTail -Output "a`nb`nc" -Lines 50
        ($out -split "`n").Count | Should -Be 3
    }
}

Describe 'Invoke-IssueRepro - manual + empty-command guards' {
    It 'returns MANUAL for type=manual without executing anything' {
        $r = Invoke-IssueRepro -Repro @{ Type = 'manual'; Command = 'whatever'; Expect = $null }
        $r.Status   | Should -Be 'MANUAL'
        $r.ExitCode | Should -Be 0
    }

    It 'fails fast when the command is empty for a non-manual type' {
        $r = Invoke-IssueRepro -Repro @{ Type = 'shell'; Command = ''; Expect = $null }
        $r.Status   | Should -Be 'FAIL'
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'empty command'
    }

    It 'returns FAIL for an unknown repro type' {
        $r = Invoke-IssueRepro -Repro @{ Type = 'bogus'; Command = 'x'; Expect = $null }
        $r.Status | Should -Be 'FAIL'
        $r.Output | Should -Match "unknown repro type 'bogus'"
    }
}

Describe 'issue-resolution-verify.yml - workflow contract' {
    BeforeAll {
        if (-not (Get-Module -ListAvailable powershell-yaml)) {
            Install-Module powershell-yaml -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop | Out-Null
        }
        Import-Module powershell-yaml -ErrorAction Stop
        $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'issue-resolution-verify.yml'
    }

    It 'exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'parses as valid YAML' {
        { ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath) } | Should -Not -Throw
    }

    It 'triggers on pull_request closed' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $on = if ($parsed.ContainsKey('on')) { $parsed['on'] } else { $parsed[$true] }
        $on.ContainsKey('pull_request') | Should -BeTrue
        @($on['pull_request']['types']) | Should -Contain 'closed'
    }

    It 'declares the required permissions' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $perms = $parsed['permissions']
        $perms['contents']      | Should -Be 'read'
        $perms['issues']        | Should -Be 'write'
        $perms['pull-requests'] | Should -Be 'write'
        $perms['actions']       | Should -Be 'read'
    }

    It 'gates the verify job on merged == true' {
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $script:WorkflowPath)
        $parsed['jobs']['verify']['if'] | Should -Match 'merged\s*==\s*true'
    }

    It 'SHA-pins every third-party uses: action' {
        $content = Get-Content -Raw $script:WorkflowPath
        $usesLines = ($content -split "`n") | Where-Object { $_ -match '^\s*-?\s*uses:\s*' }
        foreach ($line in $usesLines) {
            if ($line -match 'uses:\s*\./') { continue }
            $line | Should -Match 'uses:\s*[^@]+@[0-9a-f]{40}\b' -Because "third-party action must be SHA-pinned: $line"
        }
    }

    It 'wraps network calls with nick-fields/retry per Sloan PR #500 contract' {
        $content = Get-Content -Raw $script:WorkflowPath
        $content | Should -Match 'nick-fields/retry@ad984534de44a9489a53aefd81eb77f87c70dc60'
        $content | Should -Match 'max_attempts:\s*3'
        $content | Should -Match 'timeout_minutes:\s*10'
        $content | Should -Match 'retry_wait_seconds:\s*30'
    }

    It 'dot-sources the helper script' {
        $content = Get-Content -Raw $script:WorkflowPath
        $content | Should -Match 'Verify-IssueRepro\.ps1'
    }
}
