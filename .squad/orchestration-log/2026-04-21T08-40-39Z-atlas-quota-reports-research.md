# Orchestration Log: atlas-quota-reports-research

**Date:** 2026-04-21T08:40:39Z  
**Agent:** Atlas (background, claude-opus-4.7)  
**Task:** Research martinopedal/azure-quota-reports → integration viability verdict

## Summary

Completed viability research on azure-quota-reports repo. **Verdict: 🟢 Implement as wrapper.**

## Findings

- **Overlap:** Zero overlap with the 30 existing tools. Grep for `quota` in `tool-manifest.json` returns nothing.
- **Closest Neighbor:** WARA emits reliability advice but never enumerates `% quota used` per `(sub, region, sku)`.
- **Schema Fit:** Maps cleanly onto Schema 2.2 with no new fields needed.
- **Pattern Match:** Mirrors existing subscription-fanout pattern of `azure-cost`, `finops`, `defender-for-cloud`.

## Proposed Schema Mapping

- **Compliant Formula:** `compliant = (UsagePercent < 80%)`
- **EntityType:** `Subscription` (canonical bare GUID)
- **Pillar:** `Reliability` (Schema 2.2)
- **Category:** `Capacity` (new, recommended)
- **Severity Ladder:** Critical (≥99%), High (≥95%), Medium (≥80%), Info (below)
- **Properties Preserved:** `CurrentUsage`, `Limit`, `Unit`, `UsagePercent`, `QuotaId`, `QuotaName`, `Provider`, `Location`, `Source`

## Issues Filed

- #321: Register azure-quota in tool-manifest.json
- #322: Add modules/Invoke-AzureQuotaReports.ps1 wrapper (depends #321)
- #323: Add modules/normalizers/Normalize-AzureQuotaReports.ps1 (depends #322)
- #324: Tests for wrapper + normalizer + fixture (depends #323)
- #325: Documentation + permissions + CHANGELOG (depends #324)

**Dependency Chain:** #321 → #322 → #323 → #324 → #325

## Deliverables

- Research brief: `.squad/decisions/inbox/atlas-azure-quota-reports-research.md`
- 5 linked issues with locked schema mapping and dependency annotations
