# Atlas completion record - issue #238

- Timestamp (UTC): 2026-04-20T16:30:16Z
- Issue: #238
- PR: #273
- Merge commit: 7bdf70b588d2ab6f536d086aaa92d9f7a719c225
- Branch: feat/238-loadtesting

## Delivered
- Added Azure Load Testing wrapper (modules/Invoke-AzureLoadTesting.ps1) and normalizer (modules/normalizers/Normalize-AzureLoadTesting.ps1).
- Registered loadtesting tool in 	ools/tool-manifest.json (provider zure, scope subscription, install metadata includes Az.LoadTesting).
- Added permissions page: docs/consumer/permissions/loadtesting.md.
- Added fixtures and Pester coverage for wrapper and normalizer.
- Regenerated manifest-driven docs and permissions index.

## Runtime defaults
- DaysBack default: 30
- Regression threshold default: 10%
- Healthy findings: opt-in via -IncludeHealthyRuns

## RBAC
- Minimum requirement: Reader on the Azure Load Test resource (or inherited RG/subscription Reader).

## Validation
- Baseline before work: Passed 1213, Failed 0, Skipped 5
- Final after merge-ready updates: Passed 1254, Failed 0, Skipped 5
- Delta: +41 passed tests (repo changed during parallel merges and rebase).
