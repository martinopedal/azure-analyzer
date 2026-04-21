# ALZ Queries — Source of Truth Audit + Recommendation

**Author:** Atlas (ARG / Queries domain)
**Date:** 2026-04-22
**Status:** Recommendation, awaiting Lead approval
**Scope:** `tools/tool-manifest.json` `alz-queries` entry, `modules/Invoke-AlzQueries.ps1`, `queries/*.json`, and the relationship to `martinopedal/alz-graph-queries` and `Azure/Azure-Landing-Zones-Library`.

---

## 1. Current state (3 sources, drift map)

### Source 1 — Local `queries/` folder (15 files, runtime data)

| File | Bytes | Owner wrapper | Actually consumed? |
|---|---:|---|---|
| `alz_additional_queries.json` | 155,787 | `modules/Invoke-AlzQueries.ps1:28` | ✅ Yes — primary wrapper input |
| `finops-empty-resource-groups.json` | 1,255 | `modules/Invoke-FinOpsSignals.ps1:223` (glob `finops-*.json`) | ✅ Yes |
| `finops-idle-app-service-plans.json` | 1,180 | same | ✅ Yes |
| `finops-idle-network-controls.json` | 1,352 | same | ✅ Yes |
| `finops-stopped-vms.json` | 912 | same | ✅ Yes |
| `finops-unattached-managed-disks.json` | 935 | same | ✅ Yes |
| `finops-ungoverned-snapshots.json` | 1,756 | same | ✅ Yes |
| `finops-unused-public-ips.json` | 900 | same | ✅ Yes |
| `appinsights-slow-requests.json` | 674 | (none) — `Invoke-AppInsights.ps1` has KQL inline | ❌ **Orphan** |
| `appinsights-dependency-failures.json` | 654 | (none) | ❌ **Orphan** |
| `appinsights-exception-rate.json` | 624 | (none) | ❌ **Orphan** |
| `aks-rightsizing-missing-hpa.json` | 855 | (none) — `Invoke-AksRightsizing.ps1` has KQL inline | ❌ **Orphan** |
| `aks-rightsizing-oomkilled.json` | 717 | (none) | ❌ **Orphan** |
| `aks-rightsizing-over-provisioned.json` | 2,080 | (none) | ❌ **Orphan** |
| `aks-rightsizing-under-provisioned.json` | 2,087 | (none) | ❌ **Orphan** |

Verified by:
- `rg "queries[\\/]appinsights-|queries[\\/]aks-rightsizing-"` → only `CHANGELOG.md:44` (the announcement entry) — no wrapper reads them.
- `rg "appinsights-slow-requests|aks-rightsizing-oomkilled"` over `*.ps1` → 0 hits.
- `Invoke-AppInsights.ps1` issues hardcoded KQL strings (inspected). `Invoke-AksRightsizing.ps1:61–62` only dot-sources `shared/KqlQuery.ps1`; the per-detection queries are inline.

**Conclusion:** 7 of the 15 files in `queries/` are dead data — written once, never read by code.

### Source 2 — `martinopedal/alz-graph-queries` (the user's repo)

- Repo metadata: created 2026-03-13, last push 2026-04-20, MIT, 7 stars, default branch `main`, HEAD SHA `fd04b20a7a67571a484d852b5861506cdffdafe5`.
- Description: *"Azure Resource Graph queries for ALZ checklist items missing automated validation"* — the explicit charter is **the same problem azure-analyzer's `alz-queries` tool exists to solve**.
- Layout (root `gh api repos/.../contents`):
  - `Validate-Queries.ps1` (29,879 bytes) — standalone runner equivalent in spirit to our `Invoke-AlzQueries.ps1`.
  - `queries/alz_additional_queries.json` (153,660 bytes) — same file we ship, **drifted**.
  - `alz_checklist_full.json`, `items_no_query.json`, `items_without_queries.csv` — provenance & coverage tracking.
  - `scripts/Invoke-GraphApi.ps1`, `Invoke-CostManagementApi.ps1`, `Invoke-DevOpsApi.ps1`, `Validate-KqlSyntax.ps1` — companion modules.
  - `Tests/` — Pester suites for all of the above.
  - `THIRD_PARTY_NOTICES.md` cites the upstream-of-upstream: `Azure/review-checklists` (the Microsoft project the data is *originally* derived from).
- README declares the schema we already use (`guid`, `category`, `subcategory`, `severity`, `text`, `query`, `queryable`, `not_queryable_reason`) plus a `queryIntent` field (`findViolations` / `findEvidence`) that **our local copy does not reflect uniformly**.
- README declares 132 queryable / 206 total / 255 checklist items.

### Drift between local `queries/alz_additional_queries.json` and upstream `martinopedal/alz-graph-queries`

| | Local | Upstream | Match |
|---|---|---|---|
| Total queries | 206 | 206 | ✅ |
| Queryable (`queryable=true && graph`) | 132 | 132 | ✅ |
| Bytes | 155,787 | 153,660 | ❌ delta 2,127 |
| SHA-256 | `6B7AA23D…F44E` | `FDBD0908…6A09` | ❌ |

Same item count and same queryable count, but the file has drifted (formatting and/or minor field changes — likely the `queryIntent` field, plus whitespace from re-serialization). **Drift exists but is non-structural.** Wrapper still works because `queryIntent` is not consumed by `Invoke-AlzQueries.ps1` (it only checks for the `compliant` column in result rows).

### Source 3 — `Azure/Azure-Landing-Zones-Library` (Microsoft official)

- HEAD SHA `559a4c86fd57eddd9ee5047fb01a455866bd1cf8` (2026-04-16).
- Root contents (`gh api repos/Azure/Azure-Landing-Zones-Library/contents`): `platform/`, `schemas/`, `docs/`, `scripts/`, `Makefile`, `.editorconfig`, `.vscode/`. **No `queries/` directory.** **No ARG KQL JSON.**
- Content type: ALZ **policy / archetype library** — Bicep modules, policy definition JSON, role assignment JSON, archetype definitions consumed by AVM (Azure Verified Modules) and the ALZ accelerator. This is a *fundamentally different artifact* from ARG queries: it tells you *what to deploy* to be ALZ-compliant; ARG queries tell you *what is already deployed and whether it conforms*.

### Wrapper actual behavior — `modules/Invoke-AlzQueries.ps1`

- Default `-QueriesFile` parameter (line 28): `..\queries\alz_additional_queries.json` — **only this single file**.
- Filter (line 70): `$data.queries | Where-Object { $_.queryable -eq $true -and $_.graph }` → 132 items today.
- Compliance derivation (lines 99–107): "no rows returned ⇒ compliant; otherwise look for a `compliant` column = false".
- Docstring at line 59 directs users to `https://github.com/martinopedal/alz-graph-queries` if the file is missing — **already implicitly treats `alz-graph-queries` as the canonical source**, which contradicts `tools/tool-manifest.json:638`.

### Summary — the contradiction

| Surface | Says canonical source is | |
|---|---|---|
| `modules/Invoke-AlzQueries.ps1:59` | `martinopedal/alz-graph-queries` | (correct in spirit, exists, has the file) |
| `.copilot/copilot-instructions.md` | `alz-graph-queries` (schema reference) | (consistent with wrapper) |
| `tools/tool-manifest.json:638` | `Azure/Azure-Landing-Zones-Library` | ❌ **wrong** — that repo doesn't ship our query data |

The manifest's `upstream.repo` for `alz-queries` is misconfigured. SHA-pinning against a repo that has no relationship to the artifact we ship is a no-op at best and misleading at worst.

---

## 2. File ownership inventory (which wrapper reads which `queries/*.json`)

| File pattern | Reader | Read mechanism | Confirmed by |
|---|---|---|---|
| `alz_additional_queries.json` | `Invoke-AlzQueries.ps1` | direct path, default param | line 28 |
| `finops-*.json` | `Invoke-FinOpsSignals.ps1` | `Get-ChildItem` glob in `queries/` | line 223 |
| `appinsights-*.json` | (none) | — | grep verified zero readers |
| `aks-rightsizing-*.json` | (none) | — | grep verified zero readers |

Two implications:

1. **`Invoke-AlzQueries.ps1` owns exactly one file.** The other 14 are not its responsibility — Atlas's charter explicitly scopes "all KQL queries in `queries/alz_additional_queries.json`" (`.squad/agents/atlas/charter.md:14`). The audit confirms that scoping is correct.
2. **AppInsights/AKS JSON files were committed prospectively but never wired up.** They look like a planned refactor (move inline KQL out to data files) that stalled. They are reference / scaffolding, not runtime data.

---

## 3. Path A / B / C / D analysis

### Path A — `martinopedal/alz-graph-queries` is canonical

**Concrete changes:**
- `tools/tool-manifest.json:638-641`: change `repo` to `martinopedal/alz-graph-queries`, `releaseApi` to `…/alz-graph-queries/commits/main`, `currentPin` to actual SHA.
- New `scripts/Sync-AlzQueries.ps1` that pulls `queries/alz_additional_queries.json` from upstream into local `queries/`, idempotent, with `-CheckOnly` like `Generate-ToolCatalog.ps1`.
- New `.github/workflows/alz-queries-sync.yml` that runs daily + on `workflow_dispatch`, opens a PR if drifted (mirror the pattern used elsewhere in the repo for upstream-tracking).
- `modules/Invoke-AlzQueries.ps1:59` docstring stays as-is (already correct).
- `README.md` / `docs/contributor/operations.md`: document the sync flow.
- Backfill fix: re-sync now to clear the existing 2 KB drift.

**Pros:**
- Zero-friction match to reality: the wrapper docstring, `.copilot/copilot-instructions.md`, the schema, and the manifest finally agree.
- Atlas owns a real upstream — query authoring happens in `alz-graph-queries`, drift is detected automatically.
- `alz-graph-queries`'s `Validate-KqlSyntax.ps1` becomes a meaningful gate we can mirror or invoke.
- Provenance to `Azure/review-checklists` (the *real* Microsoft source) is preserved via `THIRD_PARTY_NOTICES.md` in upstream.

**Cons:**
- Adds a dependency on a personal repo. Bus-factor concern if `alz-graph-queries` is abandoned. Mitigation: it's MIT, fork-friendly, and we'd already have a vendored copy in `queries/`.
- The sync workflow is new ongoing maintenance.

**Breaking changes:** none — wrapper behavior unchanged, file path unchanged. SHA-pin target changes; if any downstream (e.g. SBOM, attribution dashboards) reads `upstream.currentPin`, they'd see the value flip from `HEAD` (current placeholder) to a real `alz-graph-queries` SHA. Acceptable.

### Path B — `Azure/Azure-Landing-Zones-Library` is canonical

**Concrete changes:**
- Fix `modules/Invoke-AlzQueries.ps1:59` docstring to point users at the MS Library.
- Build a translation layer that turns ALZ Library policy JSON / Bicep into ARG `compliant`-returning queries.
- Document `queries/alz_additional_queries.json` as a curated subset.
- Treat `alz-graph-queries` as personal scratch.

**Pros:**
- Microsoft-sourced provenance, zero personal-repo dependency.

**Cons:** **disqualifying**.
- The MS Library *does not contain our artifact*. It ships Bicep modules and policy assignments, not ARG KQL JSON. There is nothing to "sync".
- Building a translation layer = inventing a third source of truth in azure-analyzer; it would either be a manual rewrite (worse than today) or an autogen tool we now have to maintain.
- The MS Library tracks *what to deploy*; we need *how to detect what is deployed*. These are different problems.

**Breaking changes:** N/A — the path is infeasible.

### Path C — Three-tier model (documented split)

- MS Library = upstream policy reference, kept in manifest for narrative SHA tracking only.
- `alz-graph-queries` = curated/user-owned schema source.
- Local `queries/` = runtime, periodically synced from `alz-graph-queries`.

**Pros:**
- Honest about all three artifacts existing.

**Cons:**
- The MS Library SHA-pin is decorative — it tracks something we don't consume. SHA-pinning is supposed to mean "this is the version we ingested". A pin against an unrelated repo is misinformation in the manifest contract (`tools/tool-manifest.json` is, per `.copilot/copilot-instructions.md`, the *single source of truth* for tool registration).
- More moving parts than Path A for the same operational outcome.

**Breaking changes:** none, but it codifies the existing contradiction.

### Path D — `alz-graph-queries` retired / merged into azure-analyzer

**Concrete changes:**
- Move every artifact from `alz-graph-queries` we care about (queries JSON, `Validate-KqlSyntax.ps1`, `alz_checklist_full.json`, `items_no_query.json`) into azure-analyzer.
- Drop `upstream.repo` entirely or leave the MS Library as narrative reference (still wrong artifact, but at least it's only narrative).
- Archive `alz-graph-queries`.

**Pros:**
- One repo to maintain. Atlas's charter naturally expands to own `Validate-KqlSyntax.ps1` and the checklist provenance files.
- No cross-repo sync workflow.
- Removes the personal-repo bus-factor concern.

**Cons:**
- Loses `alz-graph-queries` as a publishable, standalone tool other Azure assessors can use without our 1300+ test runtime. The README of `alz-graph-queries` shows it has independent value — it's a fully-formed validator with its own auth waterfall and report formats.
- The `scripts/Invoke-GraphApi.ps1`, `Invoke-CostManagementApi.ps1`, `Invoke-DevOpsApi.ps1` modules from `alz-graph-queries` overlap with azure-analyzer's existing wrappers (`Invoke-EntraId*`, `Invoke-AzureCost`, `Invoke-GhAdo*`). Merging would force a deduplication project.
- Bigger blast radius than Path A.

**Breaking changes:** users of `alz-graph-queries` standalone lose upstream; `azure-analyzer` repo grows by ~400 KB plus a Pester suite that needs reconciling.

---

## 4. Recommended path

**Path A — `martinopedal/alz-graph-queries` is the canonical source for `queries/alz_additional_queries.json`.**

Rationale:
1. **Smallest change to reality.** The wrapper docstring (`modules/Invoke-AlzQueries.ps1:59`) and `.copilot/copilot-instructions.md` already say so. Only `tools/tool-manifest.json:638-641` is misaligned.
2. **The MS Library is the wrong artifact** (Path B is infeasible).
3. **Path D is premature.** `alz-graph-queries` has independent value (standalone runner, auth waterfall, KQL syntax validator, Pester suite) and a public stargazer base of 7. Burning it down to merge into azure-analyzer is a bigger conversation than this audit's scope.
4. **Path C codifies the contradiction.** A SHA-pin that tracks something we don't ingest violates the manifest contract.
5. **Drift is real but small** (2 KB, no item count change). A one-shot sync clears it; a CI workflow keeps it cleared.

---

## 5. Migration plan

Concrete, ordered, Pester-gated.

### PR 1 — Manifest + sync mechanism (`feat: alz-queries upstream realignment`)

1. **Edit `tools/tool-manifest.json:637-642`**:
   ```json
   "upstream": {
     "repo": "martinopedal/alz-graph-queries",
     "releaseApi": "https://api.github.com/repos/martinopedal/alz-graph-queries/commits/main",
     "pinType": "sha",
     "currentPin": "fd04b20a7a67571a484d852b5861506cdffdafe5"
   }
   ```
2. **Add `scripts/Sync-AlzQueries.ps1`** — manifest-driven (reads `upstream.repo` + `currentPin`), downloads `queries/alz_additional_queries.json` via the GitHub raw URL, writes to `queries/`, supports `-CheckOnly` (exit 1 on drift, mirror `Generate-ToolCatalog.ps1` ergonomics). Use `Invoke-WithRetry` and `Remove-Credentials` per `.copilot/copilot-instructions.md` shared-infrastructure rules.
3. **Add `tests/scripts/Sync-AlzQueries.Tests.ps1`** — fixture-based, mock `Invoke-WebRequest`. Cover: drift detection, `-CheckOnly` exit codes, retry on 429, manifest read failure path. **Reset `0` in `finally`** (per the war-story in atlas/history.md PR-3) so a non-zero `-CheckOnly` exit doesn't poison subsequent tests.
4. **Add `.github/workflows/alz-queries-sync.yml`** — schedule (daily 06:00 UTC), `workflow_dispatch`. On drift: open PR with label `enhancement,squad,upstream-sync`. SHA-pinned actions per repo policy.
5. **Add `alz-queries-fresh` job to `.github/workflows/docs-check.yml`** — runs `Sync-AlzQueries.ps1 -CheckOnly` on every PR. Mirrors `tool-catalog-fresh` and `permissions-pages-fresh` patterns.
6. **One-shot resync** as part of PR 1: re-run `Sync-AlzQueries.ps1` to absorb the current 2 KB drift, commit the regenerated `queries/alz_additional_queries.json`.
7. **Update `modules/Invoke-AlzQueries.ps1:59`** — keep the URL but reword: `"Run scripts\Sync-AlzQueries.ps1 to refresh from upstream, or pass -QueriesFile to override."`
8. **Docs (mandatory per `.copilot/copilot-instructions.md`):**
   - `README.md` — one-line mention of the sync workflow under the ALZ tool description.
   - `docs/consumer/permissions/alz-queries.md` — note the upstream sync.
   - `docs/contributor/operations.md` — full sync runbook (manual + scheduled).
   - `CHANGELOG.md` — Unreleased > Changed entry.
9. **Run `Invoke-Pester -Path .\tests -CI`** — must remain green (current baseline 1321/1321/5-skipped per atlas history).

### PR 2 — Per-tool query folder cleanup (separate PR, `chore: organize per-tool query files`)

See section 6.

### Out of scope (file follow-up issues, do not bundle)

- Path D evaluation (merge `alz-graph-queries` in). Worth a separate decision when/if that repo's standalone usage drops to zero.
- Building azure-analyzer-side KQL syntax validation parity with `Validate-KqlSyntax.ps1`.

---

## 6. Per-tool query folder organization

**Recommended layout:**

```
queries/
├── alz/
│   └── alz_additional_queries.json          # synced from upstream
├── finops/
│   ├── empty-resource-groups.json
│   ├── idle-app-service-plans.json
│   ├── idle-network-controls.json
│   ├── stopped-vms.json
│   ├── unattached-managed-disks.json
│   ├── ungoverned-snapshots.json
│   └── unused-public-ips.json
└── _archive/                                 # or delete outright
    ├── appinsights-*.json                    # 3 files, currently orphan
    └── aks-rightsizing-*.json                # 4 files, currently orphan
```

**Rationale:**

- **alz/ subfolder** — clean visual separation between "synced from upstream" data and "azure-analyzer–specific" data. Sync script writes to a fixed path and never touches sibling folders.
- **finops/ subfolder** — these queries are azure-analyzer-specific (no upstream), they share an owning wrapper, and they're already discovered via glob. Subfolder costs one path constant (`queries/finops/finops-*.json` → `queries/finops/*.json`) in `Invoke-FinOpsSignals.ps1:223`.
- **Per-tool repos = overkill.** 7 small JSON files per tool is not enough mass to justify cross-repo coordination. Path A's value comes from `alz_additional_queries.json` already being maintained externally; that doesn't generalize to FinOps.
- **Orphan AppInsights/AKS files** — two valid options:
  - **(preferred)** Wire them up: refactor `Invoke-AppInsights.ps1` and `Invoke-AksRightsizing.ps1` to read from JSON the way `Invoke-FinOpsSignals.ps1` does. This unblocks Atlas-style query authoring for those tools and removes the inline-KQL pattern. File a `feat:` issue, do not bundle into this PR.
  - **(if no appetite)** Delete them with a `chore:` PR + CHANGELOG > Removed entry. Shipping data that no code reads is a maintenance liability.
- **Migration risk:** moving `finops-*.json` requires updating `Invoke-FinOpsSignals.ps1:223` and the corresponding wrapper test. Single-line glob change. Pester gate catches regressions.

---

## 7. Issues to file

All carry `squad,enhancement` labels (or `chore`/`bug` as noted) per `.copilot/copilot-instructions.md` issue conventions; all titles use the required prefix.

1. **`feat: align alz-queries upstream pin with martinopedal/alz-graph-queries`** — labels `enhancement,squad`. Body = section 5 PR 1 plan. Owner: Atlas.
2. **`chore: reorganize queries/ into per-tool subfolders`** — labels `enhancement,squad`. Body = section 6 layout. Owner: Atlas. Depends on issue 1 merging first to avoid sync-script path churn.
3. **`feat: refactor AppInsights wrapper to read queries from JSON`** — labels `enhancement,squad`. Body = wire `queries/appinsights-*.json` (or moved `queries/appinsights/*.json`) into `Invoke-AppInsights.ps1`, mirror the `Invoke-FinOpsSignals.ps1` pattern. Owner: Sentinel or whichever agent owns AppInsights wrapper. Atlas can co-author the schema.
4. **`feat: refactor AksRightsizing wrapper to read queries from JSON`** — labels `enhancement,squad`. Same shape as #3.
5. **`docs: clarify alz-queries upstream contract in copilot-instructions`** — labels `documentation,squad`. Update `.copilot/copilot-instructions.md` "ARG queries live in `queries/` as JSON files" learning to also mention the sync flow + that `queries/alz/alz_additional_queries.json` is upstream-tracked vs `queries/finops/*.json` is in-repo authored. Owner: Lead.
6. **`chore: decide fate of orphan appinsights-*.json and aks-rightsizing-*.json`** — labels `enhancement,squad`. If issues 3 and 4 are not picked up within one release, delete the orphan files via this issue. Owner: Lead to triage.

---

## Appendix — citations

- `tools/tool-manifest.json:603-648` — `alz-queries` registration block (the broken `upstream.repo`).
- `modules/Invoke-AlzQueries.ps1:28,59,69-70` — wrapper input file, docstring, query filter.
- `modules/Invoke-FinOpsSignals.ps1:223,228,250-251` — only consumer of `queries/finops-*.json`.
- `modules/Invoke-AppInsights.ps1:1-60,358` — confirms inline KQL, only output-path use of `appinsights-` prefix.
- `modules/Invoke-AksRightsizing.ps1:61-62,401` — confirms inline KQL, only output-path use of `aks-rightsizing-` prefix.
- `.copilot/copilot-instructions.md` (Query format section, repo memory) — existing convention "queries live in `queries/` as JSON; `compliant` column required; see alz-graph-queries for schema".
- `.squad/agents/atlas/charter.md:14` — Atlas owns `queries/alz_additional_queries.json`.
- `gh api repos/martinopedal/alz-graph-queries` — HEAD `fd04b20a7a67571a484d852b5861506cdffdafe5`, 2026-04-20.
- `gh api repos/Azure/Azure-Landing-Zones-Library/contents` — root layout (`platform/`, `schemas/`, no `queries/`).
- File hash comparison (Get-FileHash SHA256): local `6B7AA23D…F44E` vs upstream `FDBD0908…6A09` — drifted; same query count (206 / 132 queryable).
