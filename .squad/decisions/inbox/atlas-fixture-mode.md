# Atlas: FixtureMode flag implementation (#926)

**Date:** 2026-04-24
**Author:** Atlas (ARG Specialist)
**Issue:** #926
**Branch:** `squad/926-fixture-mode`

## Decision

Add `-FixtureMode` switch to `Invoke-AzureAnalyzer.ps1` that bypasses all live Azure/GitHub/ADO infrastructure and feeds normalizers directly from fixture files in `tests/fixtures/`.

## Rationale

Contributors and CI pipelines without Azure credentials had no way to verify the full end-to-end pipeline (normalizers, EntityStore, reports). The existing E2E tests (`tests/e2e/`) test the output pipeline but require synthetic fixture construction in test code. FixtureMode uses the real fixture files that individual tool tests already maintain, exercising the actual normalizer dispatch loop in the orchestrator.

## Implementation

- **Parameter:** `-FixtureMode` switch + `-FixturePath <dir>` (default: `tests/fixtures/`)
- **Scope:** Inserted as an early-exit branch in the orchestrator (after manifest read, before scope validation), mirroring the multi-tenant fan-out pattern
- **Fixture resolution:** `<toolname>-output.json` with two hardcoded exceptions (`bicep-iac` -> `iac-bicep`, `terraform-iac` -> `iac-terraform`)
- **Coverage:** 21 of 37 tools have matching fixtures; tools without fixtures log `SKIP`
- **Output:** Full `results.json`, `entities.json` (v3.1), `report.html`, `report.md`, `dashboard.html`, `tool-status.json`

## Constraints

- FixtureMode skips: Azure auth, mandatory param prompts, prerequisite checks, incremental scan state, correlators, sinks, run history
- Fixture files are wrapper envelopes (`{Source, Status, Findings}`) — they must match what the wrappers emit
- The `-IncludeTools` / `-ExcludeTools` filters still apply in fixture mode

## Tests

14 Pester integration tests in `tests/integration/FixtureMode.Tests.ps1`:
- Exit code 0 with default fixtures
- All output artifacts created (results.json, entities.json v3.1, HTML, MD, tool-status)
- At least 3 tools produce findings
- Custom fixture path support
- Invalid fixture path error handling
- `-IncludeTools` filtering

## Status

**Proposed** — pending PR review and merge.
