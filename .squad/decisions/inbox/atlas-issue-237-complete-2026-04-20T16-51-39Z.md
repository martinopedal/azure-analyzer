# Atlas - Issue #237 complete: Application Insights perf wrapper

- **Date (UTC):** 2026-04-20T16:51:39Z
- **Agent:** Atlas
- **Issue:** [#237](https://github.com/martinopedal/azure-analyzer/issues/237) - feat: App Insights perf wrapper (KQL-driven slow request + dependency failure findings)
- **PR:** [#274](https://github.com/martinopedal/azure-analyzer/pull/274)
- **Merge SHA:** 7a4db007e9e8c61e28ebba3fcbb150e53221d578
- **Decision status:** Implemented and merged.

## Decision

Added a new manifest-registered Azure collector ppinsights with wrapper + normalizer + tests + docs.

### KQL signals and thresholds

- Slow requests: equests | where duration > 5s ... | where count_ > 10
  - Severity ladder: **Medium** when avg duration > 5s, **High** when avg duration > 30s.
- Dependency failures: dependencies | where success == false ... | where count_ > 5
  - Severity: **Medium**.
- Exception clusters: xceptions ... | where count_ > 50
  - Severity: **High**.

## Permissions summary

- **Reader** on App Insights resource scope (component/resource group/subscription).
- **Log Analytics Reader** for workspace-backed query access.

## Validation

- Pester before change: **1254 passed, 0 failed, 5 skipped**.
- Pester after change: **1264 passed, 0 failed, 5 skipped** (**+10 tests**).
- scripts/Generate-ToolCatalog.ps1 and scripts/Generate-PermissionsIndex.ps1 regenerated and committed.
- scripts/Check-StubDeadline.ps1 -Mode Check passed.
- Em-dash guard verified clean for changed files.
