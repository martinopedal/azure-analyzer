# Launch EVE smoke test report

- Date: 2026-04-21
- Requested by: martinopedal
- Worktree: `C:\git\worktrees\smoke-launch`

## 1) Baseline test gate

- Ran: `Invoke-Pester -Path .\tests -CI`
- Result: **1501 passed, 0 failed, 5 skipped**
- Baseline status: **PASS** (expected ~1490+ held)

## 2) Fixture-driven end-to-end run

Azure auth path was not used. Fixture pipeline executed:

- `tests/fixtures/azqr-output.json` -> `Normalize-Azqr`
- `tests/fixtures/psrule-output.json` -> `Normalize-PSRule`
- `tests/fixtures/kubescape-output.json` -> `Normalize-Kubescape`
- `tests/fixtures/sentinel/coverage-output.json` -> `Normalize-SentinelCoverage`
- `tests/fixtures/gitleaks-output.json` -> `Normalize-Gitleaks`
- `tests/fixtures/zizmor-output.json` -> `Normalize-Zizmor`

Aggregated via `EntityStore` to:

- `output-smoke-launch/results.json` (20 findings)
- `output-smoke-launch/entities.json` (11 entities)
- `output-smoke-launch/report.html`
- `output-smoke-launch/report.md`

## 3) Schema 2.2 rendering verification (HTML)

Verified by inspecting `output-smoke-launch/report.html`:

- Pillar visible in finding metadata rows (examples: `Security`, `Reliability`).
- Framework badges render (`fw-cis`, `fw-nist`, `fw-mitre`, etc).
- MITRE section renders for security findings with data.
- Deep links render as clickable anchors (`Open deep link`).
- Remediation snippets render in collapsible `<details><summary>...</summary>`.
- Severity distribution in header matches source findings:
  - Critical 1, High 7, Medium 8, Low 1, Info 1.

## 4) Hard bug found and fixed

### Bug
- Issue: **#415** `fix: New-HtmlReport crashes on null remediation snippets`
- Impact: full HTML report generation crash on schema 2.2 data with null snippet entries.
- Repro stack: `PropertyNotFoundException` at `New-HtmlReport.ps1:363`.

### Fix
- Patched `New-HtmlReport.ps1` snippet rendering to:
  - skip null snippet entries safely
  - support `code` and `before/after` snippet shapes
  - render snippets in collapsible details blocks
- Added regression test:
  - `tests/reports/New-HtmlReport.Tests.ps1`
  - new test case: null snippet + schema 2.2 before/after snippet.
- Validation:
  - targeted report tests green
  - full `Invoke-Pester -Path .\tests -CI` green

## 5) Cosmetic gaps (post-launch, non-blocking)

1. Some findings show a MITRE block with empty values (`Tactics:` and `Techniques:` blank). This happens when arrays contain empty strings. Suggested polish: trim empty elements before deciding to render MITRE section.
2. Overview text says "scanned 37 tools" even fixture smoke loaded 6 tool datasets. This is manifest coverage framing, not a functional error, but can confuse fixture-based smoke readers.

## 6) Launch verdict

**PASS with hard bug fixed.**

Launch blocker was found, filed, patched, and revalidated in this smoke cycle.
