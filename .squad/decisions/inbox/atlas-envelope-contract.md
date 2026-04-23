# Decision: Envelope Contract Generalization (#907)

**Date:** 2026-04-24
**Author:** Atlas (Azure Resource Graph Specialist)
**Status:** Implemented (PR #976)
**Issue:** #907

## Context

PR #841 and #847 introduced non-null `Findings` array normalization for Gitleaks and Trivy wrappers.
The remaining 35 wrappers still had inconsistent error-path returns: some missing `Errors`, some missing
`SchemaVersion`, some returning `$null`, some propagating uncaught exceptions.

## Decision

Generalize the v1 envelope contract to all 37 wrappers using the `New-WrapperEnvelope` shared helper
(introduced in PR #950). Every wrapper must:

1. Dot-source `modules/shared/New-WrapperEnvelope.ps1` with inline fallback stub
2. Use `New-WrapperEnvelope` on all catch/skip/fail paths
3. Never return `$null` from a catch block
4. Always include `Findings = @()`, `Errors = @()`, `SchemaVersion = '1.0'`

## Consequences

- All downstream consumers (normalizers, reports, orchestrator) can safely assume envelope shape
- No more `$null` reference errors when accessing `.Findings` or `.Errors` on wrapper results
- Ratchet test prevents regression — any new wrapper without envelope will fail CI
