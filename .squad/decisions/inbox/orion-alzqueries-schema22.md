# Orion Decision - Issue #400 ALZ Queries Schema 2.2

- Issue: #400 (`chore: Schema 2.2 ETL upgrade for alz-queries`)
- Branch: `feat/400-alzqueries-schema22`
- Scope completed:
  - Upgraded `modules/Invoke-AlzQueries.ps1` to emit per-finding query metadata (`Subcategory`, `QueryIntent`, `Description`, `QuerySource`, `ToolVersion`) plus top-level `ToolVersion`.
  - Upgraded `modules/normalizers/Normalize-AlzQueries.ps1` to populate Schema 2.2 fields through `New-FindingRow`: `Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, and `ToolVersion`.
  - Extended fixture-backed tests in:
    - `tests/wrappers/Invoke-AlzQueries.Tests.ps1`
    - `tests/normalizers/Normalize-AlzQueries.Tests.ps1`
    - `tests/fixtures/alz-queries-output.json`
  - Updated docs:
    - `README.md`
    - `PERMISSIONS.md`
    - `docs/consumer/permissions/alz-queries.md`
    - `CHANGELOG.md`

- Validation:
  - Baseline: `Invoke-Pester -Path .\tests -CI` passed.
  - Post-change: `Invoke-Pester -Path .\tests -CI` passed with no regressions.

