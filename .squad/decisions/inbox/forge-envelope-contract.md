# Decision: Envelope Contract Completion (#907)

**Date:** 2026-04-25
**Author:** Forge
**Status:** Implemented
**PR:** #976

## Context

Issue #907 required every wrapper to emit a consistent v1 envelope on ALL code paths: `Findings: @()` (never $null), `Errors: @()` (same), `SchemaVersion: '1.0'`, and soft-fail top-level try/catch.

An initial commit by Atlas added `Errors = @()` to many wrappers using automated regex, but missed two patterns:
1. Semicolon-separated PSCustomObject properties where `Findings` was mid-line
2. Bare `Findings = $findings` on success paths (no `@()` wrapping)

## Decision

1. **Ratchet tests are the enforcement mechanism** — automated fixers are necessary but insufficient. Cat 12 and Cat 13 in `WrapperConsistencyRatchet.Tests.ps1` block future regressions.
2. **EnvelopeContract.Tests.ps1** tests actual field presence, not whether wrappers call `New-WrapperEnvelope`. The helper is available for convenience but not mandated on every path.
3. **Inline stubs remain** — wrappers define fallback `New-WrapperEnvelope` for standalone execution. The shared `modules/shared/New-WrapperEnvelope.ps1` is the canonical definition.

## Impact

- 22 wrapper files updated with additional `Errors = @()` fields
- 7 wrappers fixed for bare `Findings = $findings` → `@($findings)`
- 240 envelope tests pass (116 static analysis + 10 helper unit + 114 ratchet)
- Full suite: 2864 passed, 0 failed
