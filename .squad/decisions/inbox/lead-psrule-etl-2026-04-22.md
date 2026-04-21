# Lead inbox drop: PSRule ETL #301 (2026-04-22)

## Context
- Target issue: #301
- Contract source: `.squad/decisions.md` Schema 2.2 lock (PR #343 / 97b8277)

## Append-only updates
- Implemented wrapper enrichment in `modules/Invoke-PSRule.ps1` for `RuleId`, severity from PSRule `Level`, `Pillar`, `Frameworks`, `BaselineTags`, `DeepLinkUrl`, and `ToolVersion`.
- Implemented normalizer pass-through in `modules/normalizers/Normalize-PSRule.ps1` using `New-FindingRow` Schema 2.2 params only.
- Added remediation snippet extraction from recommendation markdown fenced code blocks with text fallback.
- Extended fixtures and tests:
  - `tests/fixtures/psrule-raw-results.json`
  - `tests/fixtures/psrule-output.json`
  - `tests/wrappers/Invoke-PSRule.Tests.ps1`
  - `tests/normalizers/Normalize-PSRule.Tests.ps1`
- Documentation updates in this PR: `README.md`, `CHANGELOG.md`.
