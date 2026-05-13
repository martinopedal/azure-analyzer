# Decision: LiveTool test isolation pattern

**Date:** 2026-05-13  
**Agent:** Atlas  
**Issue:** #1065  
**PR:** #1117

## Context

LiveTool wrapper smoke tests (gitleaks, trivy, zizmor, scorecard) invoke real CLI binaries when available and are auto-skipped when not installed. The gitleaks smoke test was failing in the full Pester suite (3073 tests) but passing in isolation due to leaked `$LASTEXITCODE` from prior tests.

## Root Cause

Tests like `FixtureMode.Tests.ps1:23` and `Help.Tests.ps1:9` invoke `pwsh` in a subprocess, capture `$LASTEXITCODE` to verify exit code, but never reset it afterward. When LiveTool gitleaks test runs later, `Invoke-Gitleaks.ps1:437` checks:

```powershell
if ($exitCode -ne 0 -and -not (Test-Path $reportFile)) {
    return [PSCustomObject]@{ Status = 'Failed'; Message = "gitleaks exited with code $exitCode..." }
}
```

The leaked `$LASTEXITCODE` (e.g., `1` from a prior test's pwsh subprocess) triggers this branch even though gitleaks succeeded.

## Decision

**Belt-and-suspenders isolation:**
1. Add defensive `BeforeEach` in `LiveTool.Wrappers.Tests.ps1` that resets known-leaky state before each test:
   - `$global:LASTEXITCODE = 0`
   - `Get-ChildItem Env:GITLEAKS_* | Remove-Item` (env var cleanup)
   - `Set-Location $script:OriginalLocation` (working directory restore)

2. Add fail-first regression guard `LiveTool.StateIsolation.Tests.ps1` that proves isolation works even when state is deliberately polluted

## Rationale

- **Why not fix the leaking tests?** We could add `$global:LASTEXITCODE = 0` after every `$LASTEXITCODE` check across the suite, but this is fragile (easy to forget, requires per-test vigilance). Defensive isolation at the victim test is more robust.
- **Why BeforeEach instead of BeforeAll?** Each `It` block in the Describe may run in arbitrary order or be filtered by `-Tag`. BeforeEach guarantees clean state per test.
- **Why the regression guard?** The fail-first test is the durable bug-catcher. If the BeforeEach is ever removed or broken, the regression guard will fail immediately.

## Trade-offs

- **Pro:** Fixes the immediate failure; prevents similar leaks (GITLEAKS_*, GIT_*, working directory drift)
- **Pro:** Regression guard proves the fix works and catches regressions
- **Con:** Adds 3 tests to baseline (but that's acceptable per testing gate policy)
- **Con:** Doesn't fix the root leak source (but that's out of scope for this issue)

## Acceptance

All LiveTool tests pass (4 passed, 2 skipped). Full suite now passes 3171/3171 tests (baseline: 3168, +3 from new guard).

## Tags

`test-isolation`, `pester`, `livetool`, `state-leak`, `LASTEXITCODE`, `defensive-programming`
