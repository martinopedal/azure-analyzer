# Track F Commit 2 - Control-Domain Section Grouping

**Date:** 2026-04-24  
**Agent:** Atlas (Squad Core Dev)  
**PR:** #1089  
**Epic:** #506 (Track F - Auditor-driven report builder)  
**Plan ref:** `.copilot/audits/lead-track-f-impl-plan-2026-04-23.md` § 4 (lines 118-160)

## What landed

Implemented `Get-AuditorControlDomainSections` with two render helpers (`ConvertTo-AuditorControlDomainSectionsHtml` and `ConvertTo-AuditorControlDomainSectionsMd`).

**Core function:**
- Groups findings by (Framework, ControlId) tuple
- Parses `ComplianceMappings` string arrays using regex `^FRAMEWORK\s+(.+)$`
- Returns PSCustomObject array with `Framework`, `ControlId`, `FindingCount`, `Findings[]`
- Handles null/missing `ComplianceMappings` gracefully

**Render helpers:**
- HTML: minimal `<table>` markup with framework headers and control-id rows
- Markdown: standard pipe-delimited tables grouped by framework
- Both helpers consume section objects and iterate frameworks via `Group-Object`

## Fixture changes

Extended `tests/fixtures/auditor-small/results.json` from 10 to 32 findings (+22 new).

**Framework coverage added:**
- CIS 2.1.1: 10 findings (F-011 through F-018B)
- NIST AC-2: 8 findings (F-011 through F-018)
- MCSB IM-1: 7 findings (F-019 through F-025)
- ISO27001 A.9.2: 5 findings (F-026 through F-030)

Original Commit 1 tests updated to reflect new severity totals (Critical: 4, High: 14, Medium: 10, Low: 4).

## Tests added

Three new tests in `tests/shared/AuditorReportBuilder.Tests.ps1`:
1. **Test 5:** groups findings by framework control id (validates exact counts per framework/control tuple)
2. **Test 6:** handles missing ComplianceMappings gracefully (confirms no throw on null)
3. **Test 7:** renders HTML table per framework (smoke test for `<table>` presence)

**Result:** 7/7 tests passing (4 Commit 1 + 3 Commit 2).

## Render helper pattern chosen

Standalone public functions (`ConvertTo-*`) rather than methods on section objects. Matches Commit 1 style (no internal state, piping-friendly).

## Plan deviations

**None.** Plan spec assumed `ComplianceMappings` would be object arrays with `Framework`/`ControlId` properties. Reality (per existing Track D code in Commit 1) is string arrays like `["CIS 2.1.1", "NIST AC-2"]`. Adjusted implementation to parse strings via regex. No schema change required.

## Commit

`5110403` - feat(report): implement control-domain section grouping and renderers

## Next steps

Commit 3 (Remediation Appendix) - blocked until Commit 2 merges. Plan ref § 5.
