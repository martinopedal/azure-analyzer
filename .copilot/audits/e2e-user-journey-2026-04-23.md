# E2E User-Journey Audit — Iris (2026-04-23)

> ⚠️ **RECOVERY ARTIFACT.** The Iris E2E walkthrough agent reported writing a 19KB / 600-line deliverable but hit the platform Silent-Success bug — file did not persist. This file reconstructs the substance from the read_agent transcript captured by Squad Coordinator. Operative findings already spawned as fix PRs (#927 lands P0-1; lanes for P0-2 + P0-3 in flight).

## Verdict: TOOL DEGRADES ⚠️

The tool runs end-to-end and produces HTML reports successfully, but contains 3 P0 blocking issues and 3 P1 UX issues that will frustrate first-time operators. Markdown report path is fully broken pre-fix. Module import requires interactive disambiguation.

---

## Walkthrough verdict matrix

| # | Walkthrough | Verdict | Top blocker |
|---|---|---|---|
| 1 | Cold-clone install | ⚠️ | Module import hangs (P0-2) |
| 2 | Discovery / dry-run mode | ❌ | No fixture mode exists (P0-3) |
| 3 | Prereq check / installer | ⚠️ | `-InstallMissingModules` requires Azure subscription ID (P1-1) |
| 4 | Single-tool fixture run | ✅ HTML / ❌ MD | MD renderer fails on `.Compliant` (P0-1) |
| 5 | Full orchestrator dry-run | ❌ | No fixture-only profile (P0-3) |
| 6 | Report consumption | ✅ | HTML reports clean, no XSS surface, no credential leaks |
| 7 | Failure / partial-success behavior | ✅ | Graceful partial failure handling confirmed |
| 8 | Security gut-check | ✅ | No write operations, no token leaks in stdout |
| 9 | Cancellation safety | ✅ | No corrupt outputs after Ctrl+C |
| 10 | Re-run idempotency | ✅ | Byte-identical outputs across re-runs (with timestamp normalization) |

---

## P0 — Tool DOES NOT RUN end-to-end

### P0-1: Markdown report fails with `.Compliant` property error on all fixtures
- **Walkthrough:** 4
- **File:** `New-MdReport.ps1` line ~141
- **Symptom:** Renderer accesses `.Compliant` on the v1 wrapper object instead of the unwrapped findings array
- **Repro:** `pwsh -c "./New-MdReport.ps1 -InputPath ./tests/fixtures/azqr-output.json -OutputPath /tmp/test.md"` — errors on `.Compliant`
- **Root cause:** Missing wrapper-unwrapping logic that exists in `New-HtmlReport.ps1` lines 190-193
- **Fix:** 3-line wrapper unwrap added (matches HTML renderer)
- **Status:** ✅ Fixed in PR #927

### P0-2: Module import hangs prompting for mandatory parameters
- **Walkthrough:** 1
- **File:** Unknown — likely a top-level call in `AzureAnalyzer.psm1` or one of the dot-sourced `modules/shared/*.ps1`
- **Symptom:** `Import-Module ./AzureAnalyzer.psd1 -Force` triggers PowerShell's interactive mandatory-parameter prompt
- **Repro:** `pwsh -NonInteractive -c "Import-Module ./AzureAnalyzer.psd1 -Force"` — fails revealing the prompted cmdlet
- **Status:** 🟡 Fix lane in flight (`fix-module-import-p0-2`)

### P0-3: No fixture-only test mode exists
- **Walkthrough:** 5
- **File:** `Invoke-AzureAnalyzer.ps1` orchestrator entry
- **Symptom:** Cannot demonstrate or verify the tool end-to-end without provisioning a real Azure tenant + permissions
- **Impact:** Banner-down gate cannot be evidenced; CI cannot E2E; new contributors cannot validate locally
- **Fix proposal:** Add `-FixtureMode` switch that bypasses Azure auth and routes each enabled tool's normalizer against matching fixture under `tests/fixtures/`
- **Status:** 🟡 Fix lane in flight (`fix-fixture-mode-p0-3`)

---

## P1 — Tool runs but operator UX is broken

### P1-1: `-InstallMissingModules` still requires Azure subscription ID
- **Walkthrough:** 3
- **File:** `Invoke-AzureAnalyzer.ps1` parameter resolution
- **Symptom:** Prereq check happens AFTER mandatory param resolution
- **Fix:** Move prereq check before subscription ID resolution

### P1-2: No `-WhatIf` / `-DryRun` / `-ListTools` / `-ValidateConfig` flags
- **Walkthrough:** 2
- **Symptom:** No way to inspect what the orchestrator WILL do without running it
- **Fix:** Add `[CmdletBinding(SupportsShouldProcess)]` to the orchestrator + dispatch table for `-ListTools` / `-ValidateConfig`

### P1-3: `-Help` shows terse usage instead of full examples
- **Walkthrough:** 1
- **Fix:** Have the `-Help` switch internally call `Get-Help ./Invoke-AzureAnalyzer.ps1 -Full`

---

## Security findings (operator-visible)

**None of severity.** Walkthrough 8 confirmed:
- All wrappers are READ-ONLY against Azure (no `Set-` / `New-` / `Remove-` cmdlets observed)
- `-Verbose` does not leak tokens, connection strings, or PATs into stdout
- HTML report renderer escapes finding `Title`/`Remediation` correctly — `<script>` injection test did NOT execute
- Output JSON files contain no Bearer tokens, API keys, or cookie values

---

## What worked flawlessly ✅

- HTML reports across 15+ fixtures — byte-identical re-runs (with timestamp normalization)
- All wrappers read-only — no write operations against Azure
- No credential leaks in console output, log files, or report artifacts
- Graceful partial failure handling — orchestrator continues when one wrapper fails
- Cancellation safety — Ctrl+C does not produce corrupt output files
- `Get-Help` documentation quality — 88 examples across the cmdlet surface

---

## Reproducible commands (for re-verification)

```pwsh
# P0-1 (now fixed in #927)
pwsh -c "./New-MdReport.ps1 -InputPath ./tests/fixtures/azqr-output.json -OutputPath /tmp/test.md"

# P0-2
pwsh -NonInteractive -c "Import-Module ./AzureAnalyzer.psd1 -Force; 'OK'"

# P0-3 — currently has no working invocation; gating spec for #928 follow-up
# Future: pwsh ./Invoke-AzureAnalyzer.ps1 -FixtureMode -OutputPath /tmp/fixture-test

# P1-1
pwsh ./Invoke-AzureAnalyzer.ps1 -InstallMissingModules
# observed: prompts for subscription ID before checking prereqs

# Walkthrough 4 (HTML happy path)
pwsh -c "Import-Module ./AzureAnalyzer.psd1 -Force; ./New-HtmlReport.ps1 -InputPath ./tests/fixtures/azqr-output.json -OutputPath /tmp/test.html"
# exits 0, produces non-empty HTML
```

## Total estimated remediation: ~90 minutes for a PowerShell-experienced contributor
