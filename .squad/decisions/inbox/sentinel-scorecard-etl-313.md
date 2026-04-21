# Sentinel Scorecard ETL history (#313)

## 2026-04-21T00:00:00Z
- Started Sentinel implementation for OpenSSF Scorecard wrapper + normalizer ETL closure to Schema 2.2.
- Locked scope from issue #313 plus `.squad/decisions.md` Schema 2.2 contract and severity bug note.

## 2026-04-21T00:30:00Z
- Updated `modules/Invoke-Scorecard.ps1` to capture scorecard tool version, baseline tag, deep-link URL, pillar, frameworks, remediation snippets, check details, and score-driven severity.
- Added static category mapping and SLSA framework controls where applicable.

## 2026-04-21T01:00:00Z
- Updated `modules/normalizers/Normalize-Scorecard.ps1` to emit Schema 2.2 fields via `New-FindingRow` only.
- Implemented EvidenceUris extraction from scorecard check details (URLs, commit SHAs, file paths).

## 2026-04-21T01:30:00Z
- Extended fixtures and tests for wrapper and normalizer, including score boundary severity mapping and repository dedup check via `Merge-UniqueByKey`.
- Updated `CHANGELOG.md` and `README.md`; confirmed `PERMISSIONS.md` unchanged per task scope.
