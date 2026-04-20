# Sentinel completion record - issue #226

## Issue
- #226 feat(reports): severity totals strip on every findings tab

## Delivery summary
- Implemented sticky per-category severity totals strip in `New-HtmlReport.ps1` for each findings category panel.
- Strip shows: Critical, High, Medium, Low, Info, and a right-aligned Total.
- Added click-to-filter by wiring strip badges into existing global severity filtering logic.
- Added Info to the global severity chips so all five severities are filterable from the findings UI.

## Validation
- Baseline before change: discovery found 1218 tests.
- After change: `Invoke-Pester -Path .\tests -CI` passed with `Tests Passed: 1214, Failed: 0, Skipped: 5`.
- Added test coverage: `tests/reports/Severity-Strip.Tests.ps1` verifies strip markup and severity totals.

## PR and merge
- PR: https://github.com/martinopedal/azure-analyzer/pull/270
- Merge commit: 68da519604f74e26a1f2ec09788753c63b41988d
- Merged at: 2026-04-20T16:06:12Z

## Screenshot description
- In generated `report.html`, each findings category section now has a sticky badge row directly under the category header:
  - `Critical: N | High: N | Medium: N | Low: N | Info: N`
  - `Total: N` on the right
- Clicking any severity badge applies the existing findings severity filter and updates visible table rows.

## Related context
- Lead triage doc: `.squad/decisions/inbox/lead-backlog-triage-2026-04-20-aks-reports-cost-173025.md`
