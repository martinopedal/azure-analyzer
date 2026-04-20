# Project Context

- **Owner:** martinopedal
- **Project:** azure-analyzer — Automated Azure assessment bundling azqr, PSRule, AzGovViz, and ALZ Resource Graph queries
- **Stack:** Python (orchestrator), KQL/ARG queries (JSON), PowerShell, GitHub Actions
- **Created:** 2026-04-15

## Learnings

- ARG queries live in `queries/` as JSON files, not .kql files
- Every query must return a `compliant` column (boolean)
- Query schema reference: alz-graph-queries repo
- All Azure tool invocations are read-only (Reader role only)
- Output is written to `output/` directory which is gitignored

## 2026-04-19 Session Outcomes

- Issue #166 delivered and merged via PR #182 (`6bb07aec6277a04ff3ed1a412eb5155fbcf16944`).
- Added Azure DevOps repo secret scanning and pipeline run-log correlation with wrapper/normalizer tests and fixtures.
- Updated docs in the same change set (`README.md`, `PERMISSIONS.md`, `CHANGELOG.md`) per repo rules.
- Noted `rubberduck-gate` degraded/advisory failure path and linked fix in `modules/shared/Get-CopilotReviewFindings.ps1` (owner/repo normalization for GraphQL calls).
- Post-merge follow-ups opened for deferred ADO scope:
  - #197 Azure DevOps Server/on-prem support
  - #198 Private-repo access edge cases
  - #199 Advanced gitleaks pattern strategy
