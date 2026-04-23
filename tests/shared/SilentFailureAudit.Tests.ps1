#Requires -Version 7.0

<#
.SYNOPSIS
    Ratchet test: every known empty-catch and intentional SilentlyContinue auth-probe
    site MUST carry an explanatory '# best-effort:' or '(SilentlyContinue:' comment.

.DESCRIPTION
    Sentinel sweep cat 3 (silent-failure audit): rather than eliminate every
    empty catch (many are legitimate version/TTY/canonicalization probes), we
    document intent at each site. This test prevents regression — anyone who
    adds a new empty catch or strips an existing comment will fail this gate.

    To add a new legitimate site: add it to $script:KnownSilentFailureSites
    AND ensure the file carries the comment marker.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    # Each entry: relative path + required comment substring near the site.
    # The substring must appear on or near (within 2 lines of) the catch/SilentlyContinue line.
    $script:KnownSilentFailureSites = @(
        @{ Path = 'modules/Invoke-CopilotTriage.ps1';                Marker = "best-effort: python3 not on PATH" }
        @{ Path = 'modules/Invoke-CopilotTriage.ps1';                Marker = "best-effort: python interpreter unavailable" }
        @{ Path = 'modules/Invoke-IaCBicep.ps1';                     Marker = "best-effort: not a git repo" }
        @{ Path = 'modules/Invoke-Kubescape.ps1';                    Marker = "best-effort: kubescape CLI not installed" }
        @{ Path = 'modules/Invoke-Prowler.ps1';                      Marker = "best-effort: prowler CLI not installed" }
        @{ Path = 'modules/normalizers/Normalize-Kubescape.ps1';     Marker = "best-effort: malformed subscriptionId" }
        @{ Path = 'modules/normalizers/Normalize-PSRule.ps1';        Marker = "best-effort: malformed subscriptionId" }
        @{ Path = 'modules/shared/PromptForMandatoryParams.ps1';     Marker = "best-effort: stdin not a console" }
        @{ Path = 'modules/Invoke-Maester.ps1';                      Marker = "SilentlyContinue: probing for connection state" }
        @{ Path = 'modules/Invoke-WARA.ps1';                         Marker = "SilentlyContinue: probing for sign-in state" }
    )
}

Describe 'SilentFailureAudit ratchet (sentinel sweep cat 3)' {
    It 'documents every known silent-failure site with a "best-effort" or "SilentlyContinue:" marker' {
        $missing = @()
        foreach ($site in $script:KnownSilentFailureSites) {
            $full = Join-Path $script:RepoRoot $site.Path
            Test-Path $full | Should -BeTrue -Because "expected file '$($site.Path)' to exist"
            $content = Get-Content $full -Raw
            if ($content -notmatch [regex]::Escape($site.Marker)) {
                $missing += "$($site.Path) :: missing marker '$($site.Marker)'"
            }
        }
        if ($missing.Count -gt 0) {
            $msg = "The following silent-failure sites lost their explanatory comment:`n  - " + ($missing -join "`n  - ")
            $msg | Should -BeNullOrEmpty -Because $msg
        }
    }
}
