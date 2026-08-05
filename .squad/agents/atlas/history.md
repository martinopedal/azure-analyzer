# Project Context

- **Owner:** martinopedal
- **Project:** azure-analyzer - Automated Azure assessment bundling azqr, PSRule, AzGovViz, and ALZ Resource Graph queries
- **Stack:** PowerShell, JSON, KQL/ARG queries, GitHub Actions
- **Created:** 2026-04-15

## Core Context

- **ARG Queries:** ARG queries live in queries/ as JSON and must return a compliant boolean. All Azure tool invocations are read-only (Reader role).
- **Tool Catalog & Permissions:** Generated via Generate-ToolCatalog.ps1 and Generate-PermissionsIndex.ps1 (manifest-driven, checked in CI).
- **Em-Dash Policy:** Strict zero-tolerance for em-dashes (-) in new markdown files. Use plain hyphens (-).
- **Pester & Exit Codes:** Any Pester test invoking a script expected to exit non-zero MUST reset $LASTEXITCODE in inally/AfterAll.
- **FixtureMode:** Pre-fetched offline contract for fast offline testing/validation without live Azure access.

## Recent History

### 2026-04-22 - Report UX & AzGovViz Deep Dive
- Architecture decision: single-page scroll with sticky anchor pills, no JS TabStrip.
- Schema 2.2 contract locked with 13 optional FindingRow fields.

### 2026-05-13 - RemoteClone Shared Infra Refactor (PR #1069)
- Refactored all git-based wrappers to use modules/shared/RemoteClone.ps1.
- Enforces HTTPS-only URLs and host allow-listing (github.com, dev.azure.com, *.visualstudio.com).

### 2026-05-13 - Static Mock Leakage Audit
- Verified 0 fake-success or mock-leakage paths in production modules.

### 2026-08-05 - Team Update
- Windows CI restored on GitHub-hosted runners (PR #1250 / #1173).
- Native false-positive suppression list shipped (PR #1251 / #1229).
- Backlog of 48 tool-pin PRs deduped down to 16 keepers.