#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Architecture + structural guardrails for the legacy Copilot triage wrapper.

.DESCRIPTION
    `modules/Invoke-CopilotTriage.ps1` is a deliberately orphaned wrapper:
    the orchestrator wires Copilot AI triage to the sanitizing PowerShell
    module at `modules/shared/Triage/Invoke-CopilotTriage.ps1` instead, and
    the manifest registers `copilot-triage` with `enabled: false` and the
    same shared/Triage script path. See `.copilot/audits/atlas-manifest-audit-2026-04-23.md`.

    Behavioural timeout coverage for the supported execution path lives in
    `tests/shared/Triage/Invoke-CopilotTriage.Timeout.Tests.ps1` (dot-source
    pattern, exercises `Invoke-WithTimeout` mocks against in-scope functions).

    The legacy wrapper is still file-resident because external scripts could
    invoke it directly. These tests assert two contracts:

      1. The legacy script keeps its `Invoke-WithTimeout` fallback stub +
         lazy-load gate so any future direct invocation continues to enjoy
         CliTimeout protection without breaking Pester mocks.

      2. The orchestrator + manifest never re-introduce a wire from
         production code into the legacy wrapper (would silently bypass
         `Remove-Credentials` sanitization — round-2 triage bottom-fix).
#>

BeforeAll {
    $script:RepoRoot         = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:LegacyModulePath = Join-Path $script:RepoRoot 'modules\Invoke-CopilotTriage.ps1'
    $script:LiveModulePath   = Join-Path $script:RepoRoot 'modules\shared\Triage\Invoke-CopilotTriage.ps1'
    $script:OrchestratorPath = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
    $script:ManifestPath     = Join-Path $script:RepoRoot 'tools\tool-manifest.json'
}

Describe 'Invoke-CopilotTriage architectural + structural guardrails' -Tag 'AllowsWarning' {
    Context 'Orphaned-by-design contract (legacy wrapper not orchestrated)' {
        It 'orchestrator wires AI triage to the sanitizing shared/Triage module, not the legacy wrapper' {
            $orchestrator = Get-Content -LiteralPath $script:OrchestratorPath -Raw
            $orchestrator | Should -Match "shared['\\/]+Triage['\\/]+Invoke-CopilotTriage\.ps1"
            # The legacy path must NOT appear as an executable wire-in. Allow comment lines that document the deprecation.
            $executableMatches = Select-String -Path $script:OrchestratorPath -Pattern 'modules[\\/]+Invoke-CopilotTriage\.ps1' |
                Where-Object { $_.Line -notmatch '^\s*#' }
            $executableMatches | Should -BeNullOrEmpty -Because 'legacy wrapper bypassed Remove-Credentials and must not be re-introduced as an execution path (round-2 triage bottom-fix).'
        }

        It 'tool manifest registers copilot-triage against the shared/Triage script path with enabled=false' {
            $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $entry = $manifest.tools | Where-Object { $_.name -eq 'copilot-triage' }
            $entry            | Should -Not -BeNullOrEmpty
            $entry.script     | Should -Match 'shared[\\/]+Triage[\\/]+Invoke-CopilotTriage\.ps1'
            $entry.enabled    | Should -BeFalse -Because 'AI triage is opt-in via -EnableAiTriage and ships disabled.'
        }
    }

    Context 'Legacy wrapper still hardens its Python subprocess timeout (defensive depth)' {
        It 'wraps the Python subprocess invocation with Invoke-WithTimeout -TimeoutSec 300' {
            $content = Get-Content -LiteralPath $script:LegacyModulePath -Raw
            $content | Should -Match 'Invoke-WithTimeout\s+-Command\s+\$py\s+-Arguments\s+\$args\s+-TimeoutSec\s+300'
        }

        It 'emits a TimeoutExceeded finding error when the Python subprocess exits with -1' {
            $content = Get-Content -LiteralPath $script:LegacyModulePath -Raw
            $content | Should -Match 'if\s*\(\s*\$result\.ExitCode\s+-eq\s+-1\s*\)'
            $content | Should -Match "-Category\s+'TimeoutExceeded'"
            $content | Should -Match 'Python\s+triage\s+subprocess\s+timed\s+out'
        }

        It 'returns a Failed-status envelope (not Skipped) on subprocess timeout' {
            $content = Get-Content -LiteralPath $script:LegacyModulePath -Raw
            $content | Should -Match "-Status\s+'Failed'\s+-Message\s+'Python\s+subprocess\s+timed\s+out'"
        }

        It 'includes the Invoke-WithTimeout fallback stub + Get-Command lazy-load gate so Pester mocks are not shadowed' {
            $content = Get-Content -LiteralPath $script:LegacyModulePath -Raw
            $content | Should -Match 'function\s+Invoke-WithTimeout'
            $content | Should -Match 'if\s*\(-not\s*\(Get-Command\s+Invoke-WithTimeout'
        }
    }
}
