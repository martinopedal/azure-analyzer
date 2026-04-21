# `queries/` - ARG and KQL query catalogs

This folder is the home of every JSON query catalog the orchestrator (or a wrapper) reads at runtime, plus a hand-curated reference library.

## Layout convention

Each runtime query catalog lives in a **per-tool subfolder** named after its owning wrapper. The wrapper reads only from its own subfolder; no wrapper scans the top of `queries/`.

| Subfolder        | Owner                              | Loaded by                         |
| ---------------- | ---------------------------------- | --------------------------------- |
| `queries/alz/`     | `alz-queries` tool                 | `modules/Invoke-AlzQueries.ps1`     |
| `queries/finops/`  | `finops` tool                      | `modules/Invoke-FinOpsSignals.ps1`  |
| `queries/library/` | reference-only (no wrapper reads)  | not loaded - see `library/README.md` |

`queries/alz/alz_additional_queries.json` is kept in sync with the canonical upstream `martinopedal/alz-graph-queries` via `scripts/Sync-AlzQueries.ps1`.

`queries/finops/finops-*.json` are read via a `Get-ChildItem -Filter 'finops-*.json'` glob inside `modules/Invoke-FinOpsSignals.ps1`.

## Adding a new query catalog

1. Pick or create a per-tool subfolder under `queries/` named after the owning wrapper or tool family (kebab-case, short).
2. Every query MUST emit a boolean `compliant` column - see the schema in `martinopedal/alz-graph-queries`.
3. Wire it up from a single owning wrapper. Do **not** drop runtime catalogs at the top of `queries/`.
4. If the catalog is reference-only (mirror of inline KQL embedded in a wrapper), put it under `queries/library/` and document its origin in `library/README.md`.
