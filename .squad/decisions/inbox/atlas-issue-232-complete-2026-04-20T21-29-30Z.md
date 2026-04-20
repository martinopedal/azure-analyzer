# Atlas - Issue #232 complete: CI/CD cost telemetry

- **Date (UTC):** 2026-04-20T21:29:30Z
- **Agent:** Atlas
- **Issue:** [#232](https://github.com/martinopedal/azure-analyzer/issues/232) - feat: CI/CD cost telemetry (GH Actions billing + ADO consumption)
- **Decision status:** Implemented locally (pending PR and merge flow).

## Tool split decision

Implemented two wrappers and two manifest entries:

- `gh-actions-billing` (provider `github`)
- `ado-consumption` (provider `ado`)

Rationale: independent auth surfaces, independent enable/disable controls, and cleaner permission docs.

## Threshold defaults

- GitHub org over-budget: `included_minutes_used > included_minutes` (High)
- GitHub run anomaly: run duration `> 60 minutes` and `> 2x` peer baseline (Low)
- ADO project share: `>= 40%` of org runner minutes (Medium)
- ADO duration regression: second-half average `> 25%` above first-half average (Medium)
- ADO failed run rate: `> 10%` (High)
- Optional `MonthlyBudgetUsd` threshold on both wrappers uses an estimated USD/min model.

## Validation snapshot

- Pester baseline before change: **1307 discovered, 1307 passed**.
- Pester after change: **1326 discovered, 1321 passed, 0 failed, 5 skipped**.
- New test delta: **+19 tests** (wrappers + normalizers).
- Manifest-driven docs regenerated:
  - `scripts/Generate-ToolCatalog.ps1`
  - `scripts/Generate-PermissionsIndex.ps1`
