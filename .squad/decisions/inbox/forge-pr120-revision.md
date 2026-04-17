# Forge Decision — PR #120 revision for issue #126 gate

- **Date:** 2026-04-17
- **Owner:** Forge
- **Context:** PR #120 on branch `feat/98-wrapper-error-paths` required gate-driven revisions from issue #126.

## Decision

1. **Parser safety:** `Invoke-KubeBench.ps1` title formatting uses `"${testNumber}: $testDesc"` to avoid parser scope-qualifier ambiguity.
2. **Test hard-fail behavior:** wrapper Pester tests set `$ErrorActionPreference = 'Stop'` so parse/runtime errors surface immediately (no swallow pattern in kube-bench tests).
3. **Retry API alignment:** `Invoke-WithRetry` uses canonical `-MaxAttempts`; backward-compat `-MaxRetries` remains supported and mapped to retry semantics.
4. **Sanitization invariant:** exception-derived message/log text in all 17 wrappers must pass through `Remove-Credentials` before returning or writing logs.
5. **Multi-target status semantics:** wrappers scanning multiple clusters/projects return `PartialSuccess` when successes and failures coexist (kube-bench, kubescape, falco install mode), while retaining successful findings.

## Impact

- Prevents parse regressions from string interpolation edge cases.
- Improves test signal by exposing parser faults directly.
- Keeps wrapper retry usage consistent across PR #119/#120 compatibility boundary.
- Reduces secret leakage risk in wrapper JSON/log outputs.
- Preserves useful findings during partial scan outages instead of over-reporting full failure.
