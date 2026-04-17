# Decision: PR #116 Re-Gate Extension

**Date:** 2026-04-18  
**Agent:** Forge  
**PR:** #116  
**Status:** ✅ Complete

## Context

Lead re-gate rejected #116 because `Remove-Credentials` remained undefined in four parallel-runspace callsites. In PowerShell 7, `ForEach-Object -Parallel` creates isolated runspaces, so parent-scope functions are not inherited.

## Decision

Apply the Falco-established pattern to all missing runspace boundaries:

- Dot-source `shared/Sanitize.ps1` in:
  - `modules/Invoke-AzureCost.ps1`
  - `modules/Invoke-DefenderForCloud.ps1`
  - `modules/Invoke-Kubescape.ps1`
- Add dot-source + fallback inside `Invoke-AzureAnalyzer.ps1` `$runnerBlock` before invoking wrappers.
- Keep fallback stub:
  - `if (-not (Get-Command Remove-Credentials ...)) { function Remove-Credentials { ... } }`

## Rationale

- Guarantees `Remove-Credentials` exists at runtime in each isolated worker runspace.
- Preserves sanitized error handling instead of cascading into `CommandNotFoundException`.
- Reuses existing, accepted pattern for consistency across wrappers.

## Validation

- `Invoke-Pester -Path .\tests -CI` → **398 passed, 0 failed**.
