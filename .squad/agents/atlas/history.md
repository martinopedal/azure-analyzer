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
