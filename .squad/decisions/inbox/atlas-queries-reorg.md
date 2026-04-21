# Decision: queries/ reorganized into per-tool subfolders

**Date:** 2026-04-21
**Author:** Atlas
**Issue:** #317
**PR:** #335 (merged at `b8aa059`)
**Status:** Inbox - ratify into `decisions.md` next sweep.

## Context

`queries/` was a flat folder mixing three different concerns:

1. `alz_additional_queries.json` - the canonical ALZ ARG query catalog, owned by `Invoke-AlzQueries.ps1`, kept in sync from `martinopedal/alz-graph-queries` by `scripts/Sync-AlzQueries.ps1` (PR #331, Forge).
2. Seven `finops-*.json` catalogs read via a `Get-ChildItem -Filter 'finops-*.json'` glob inside `Invoke-FinOpsSignals.ps1`.
3. `library/` (PR #327, Atlas) - 8 reference-only files mirroring inline-wrapper KQL with a README explaining they are operator docs, not data.

Wrapper ownership of (1) and (2) was invisible at the file-tree level, and the orphan-query audit (decisions.md - ALZ Queries SoT) had already shown that `Get-ChildItem` glob ownership is also invisible to grep. Adding more wrappers to the flat layout would have compounded the confusion.

## Decision

Per-tool subfolder per owning wrapper. Convention codified in new `queries/README.md`:

| Subfolder        | Owner       | Loaded by                         |
| ---------------- | ----------- | --------------------------------- |
| `queries/alz/`     | alz-queries | `modules/Invoke-AlzQueries.ps1`     |
| `queries/finops/`  | finops      | `modules/Invoke-FinOpsSignals.ps1`  |
| `queries/library/` | reference   | (no wrapper - operator docs only) |

All 8 runtime files moved via `git mv` to preserve blame. `library/` left intact - subdivision rejected (only 8 files, README explains origin, would be premature folder churn).

## Alternatives considered

- **`queries/alz-graph-queries/`** instead of `queries/alz/` - rejected. Bakes the upstream repo name into the local layout; `alz/` matches the wrapper basename (`Invoke-AlzQueries`) and the manifest tool name (`alz-queries`).
- **Subdivide `library/` now** (e.g. `library/aks-rightsizing/`, `library/appinsights/`) - rejected. Out of scope for #317; 8 files do not justify it.
- **Top-level `library/` flattened** to remove the level - rejected. Would re-mix reference and runtime concerns and contradict #318.

## Consequences

- Future tools that ship a runtime query catalog drop it under their own `queries/<tool-name>/` subfolder. README documents the rule.
- Wrapper defaults for `Invoke-AlzQueries.ps1` and `Invoke-FinOpsSignals.ps1`, the destination default for `Sync-AlzQueries.ps1`, and the affected tests (`Sync-AlzQueries.Tests.ps1`, `Invoke-FinOpsSignals.Tests.ps1`) updated in the same commit.
- README.md, docs/consumer/permissions/finops.md, queries/library/README.md updated; CHANGELOG.md entry added.
- Pester baseline preserved at 1354/1354.
- 3-of-3 rubber-duck APPROVE (Opus 4.6, GPT-5.3-codex, Goldeneye) before implementation.

## Cross-refs

- decisions.md - ALZ Queries SoT (orphan-query audit, glob-ownership lesson)
- PR #327 - `queries/library/` introduction
- PR #331 - `Sync-AlzQueries.ps1` (wrote to top-level pre-reorg)
- Issue #318 - library subfolder
