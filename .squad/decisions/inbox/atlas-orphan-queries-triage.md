# Atlas - Orphan query triage (#318 -> PR #327)

**Date:** 2026-04-22
**PR:** https://github.com/martinopedal/azure-analyzer/pull/327
**Merge SHA:** 9c6ab7d7c1f0aff798a6767eb6ae8ee29d29ee2d
**Issue:** https://github.com/martinopedal/azure-analyzer/issues/318

## Verdict: all 7 -> (c) move to `queries/library/` + README

The orphans identified in the prior ALZ-queries source-of-truth audit were re-confirmed by listing `queries/*.json` and `rg`-grepping every filename across `modules/`, `tests/`, `scripts/`. Zero hits per file -> true orphans.

| File | Fate | Mirrors inline KQL in |
| --- | --- | --- |
| `appinsights-slow-requests.json` | (c) library | `Invoke-AppInsights.ps1` `$slowRequestQuery` |
| `appinsights-dependency-failures.json` | (c) library | `Invoke-AppInsights.ps1` `$dependencyFailureQuery` |
| `appinsights-exception-rate.json` | (c) library | `Invoke-AppInsights.ps1` `$exceptionRateQuery` |
| `aks-rightsizing-missing-hpa.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |
| `aks-rightsizing-oomkilled.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |
| `aks-rightsizing-over-provisioned.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |
| `aks-rightsizing-under-provisioned.json` | (c) library | `Invoke-AksRightsizing.ps1` `$querySet` |

## Why uniform (c), not (a) delete or (b) wire up

- **(a) delete rejected:** Each file is a hand-curated catalog that aligns 1:1 with shipped detections. Files have operator-facing reference value (copy-paste into Log Analytics blade) and are an obvious extraction target if a future refactor moves inline KQL to JSON. Deletion is permanent loss of curation that nothing else captures.
- **(b) wire up rejected:** Both wrappers already ship complete, working inline KQL. Refactoring to JSON-loaded queries is a non-trivial change with its own normalizer/test surface and regression risk. Out of scope for an orphan-triage bug.
- **(c) library accepted:** `queries/library/` + a README codifies the convention so the next orphan-query audit will not re-flag these. README enumerates current contents, which wrapper each file mirrors, and the rules for adding new entries (sync with wrapper inline KQL, schema, do-not-put-loaded-files-here).

## Codified convention (new)

`queries/` is now split into two zones:

- `queries/*.json` (top level) -> **read by a wrapper**. The orchestrator depends on these.
- `queries/library/*.json` -> **reference catalogs**. Not loaded by any wrapper. Mirror inline KQL elsewhere in the repo.

The `queries/library/README.md` documents this and lists which wrapper each file mirrors. Future orphan audits should treat anything at the top of `queries/` not referenced by a wrapper as a candidate for either wiring up or moving to `library/`. Default to wiring up if data is valuable; default to moving to `library/` if the wrapper already has the same KQL inline.

## Verification

- `Invoke-Pester -Path .\tests -CI` -> **1349 passed / 0 failed / 5 skipped** (baseline preserved).
- All required CI checks green; `Analyze (actions)` green; `mergeStateStatus=CLEAN`.
- Em-dash gate clean.
- No Copilot review comments after ~3 min wait window. Squash-merged with `--delete-branch`.

## Follow-up (proposed, not filed)

A separate refactor could promote `queries/library/` to actual loaded queries by extracting inline KQL from `Invoke-AppInsights.ps1` and `Invoke-AksRightsizing.ps1`. That is a deliberate design choice (single source of truth in JSON), not an orphan-triage decision. File only if there is concrete value (e.g. user-customizable KQL thresholds without code edits).

## Learnings worth pulling into core context

- `git mv` of a true orphan produces zero Pester failures. Useful as a fast confirmation step for orphan audits: move to a sibling folder, run tests, watch for surprises.
- `gh pr merge --squash` invoked from inside a worktree fails with `'main' is already used by worktree at <root>`. Run merge from the repo root, from any path outside the worktree, or pass `--repo`. Mirrors the existing worktree-cleanup-from-root rule.
- CHANGELOG.md currently has two `Unreleased` headings; `[1.2.0 - Unreleased]` is the active band. Add new entries there, not in the older `[Unreleased]` legacy band below it.
- Em-dash gate (`rg -- "—"`) recursively scans new subdirectories too. New `README.md` files inside fresh folders need scrubbing before commit.
