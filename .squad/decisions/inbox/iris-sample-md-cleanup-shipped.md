# Sample MD cleanup + generator-path verification (shipped)

**PR:** #421 (squash-merged into main, branch deleted)
**Branch:** chore/v2-sample-md-and-generator-path
**Date:** 2026-04-21

## Generator-path question
Investigated whether `New-HtmlReport.ps1` and `New-MdReport.ps1` at the repo root were misplaced (vs. `scripts/`).

**Verdict: intentional, no move needed.**

Both files are public module entry-points exported by `AzureAnalyzer.psd1` (`FunctionsToExport`), wrapped by `AzureAnalyzer.psm1`, and invoked from `Invoke-AzureAnalyzer.ps1` via `& "$PSScriptRoot\New-HtmlReport.ps1"` (line 1490) and `& "$PSScriptRoot\New-MdReport.ps1"` (line 1497). They live as siblings of `Invoke-AzureAnalyzer.ps1` by design. `scripts/` only holds tooling like `Generate-ToolCatalog.ps1` and never held the report generators. There is no duplicate.

## Samples regenerated
Re-ran both generators against the curated `samples/sample-findings-v2.json` (11 findings, posture 9/100, 1 Critical / 4 High / 5 Medium / 0 Low):

- `samples/sample-report.html` — refreshed (66 KB to 96 KB; 22 v2 markers preserved). The previously checked-in HTML had been generated from a smaller 5-finding fixture and was therefore inconsistent with the v2 dataset that the MD sample reflected. Now both samples render the same data.
- `samples/sample-report.md` — re-emitted by the generator, byte-identical to what was already in `main`. The "stale" perception was an mtime artifact; the content was already aligned with `sample-findings-v2.json`.

`samples/sample-report-v2-mockup.{html,md}` (Sage's source-of-truth) were not touched.

## Tests
`Invoke-Pester -Path .\tests\reports -CI` — 24/24 passed.

## CI
All 14 required and optional checks green on first push (Analyze (actions), Test x3 OS, CodeQL, markdown-link-check, docs-check, advisory-gate, etc.). No Copilot review comments. Admin-squash-merged.
