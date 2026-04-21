# Project Context

- **Owner:** martinopedal
- **Project:** azure-analyzer - Automated Azure assessment bundling azqr, PSRule, AzGovViz, and ALZ Resource Graph queries
- **Stack:** Python (orchestrator), KQL/ARG queries (JSON), PowerShell, GitHub Actions
- **Created:** 2026-04-15

## Core Context

Accumulated learnings from prior sessions (summarized 2026-04-22):

- ARG queries live in `queries/` as JSON, must return `compliant` boolean. All Azure tool invocations read-only (Reader role).
- `docs-check.yml` detection uses inline JS snippet with `ignoredPatterns` + `isDoc` predicate. After restructure: `docPathPatterns.some(p => p.test(f))`.
- Em-dash gate is zero-tolerance: `rg -- "-"` over every `.md` before commit.
- `git mv` + stub at old path defeats rename detection in `git status` (shows M+A not R); `git log --follow` still works.
- Parallel `git commit` calls collide on `index.lock` — always serialize.
- Authority limits trump sweep instructions — don't touch README/CHANGELOG if off-limits in the PR scope.
- Inbound-link search: exclude `.squad/agents/*/history.md`, `.squad/log/**`, `.squad/orchestration-log/**` (append-only logs, outdated paths are truth).
- Required check is `Analyze (actions)` (CodeQL). `rubberduck-gate` reports "Gate skipped: non-squad-author" on solo runs.

## 2026-04-19 Session Outcomes

- Issue #166 delivered and merged via PR #182 (`6bb07aec`).
- Added Azure DevOps repo secret scanning and pipeline run-log correlation.
- Post-merge follow-ups: #197 ADO Server, #198 private-repo edge cases, #199 advanced gitleaks patterns.

## 2026-04-20 PR-1 Foundation Restructure (PR #243, squash-merge ed6041d0)

Landed 5-PR consumer-first doc restructure PR-1: 9 doc moves under `docs/consumer/` and `docs/contributor/`, redirect stubs, two index pages, `docs-check.yml` updates. All 11 checks green on first run.

### 2026-04-22 - Report UX arc: AzGovViz deep-dive completed

- Brief merged to `decisions.md`. Architecture decision ratified: **single-page scroll with sticky anchor pills, no JS TabStrip.** AzGovViz ETL fix tracked as #307.
- Key wrapper gaps: `*_HierarchyMap.json` not parsed (blocks MG ancestry breadcrumbs), AzAdvertizer URLs dropped, PIM eligibility flag not extracted.
- CSS-only management-group tree adopted as a reusable primitive. TableFilter (vanilla JS, MIT) recommended over jQuery DataTables.
- Schema 2.2 contract locked with 13 new optional FindingRow fields (#299 umbrella issue).
- **Required check is `Analyze (actions)`** (CodeQL). All other checks (CI matrix, Docs Check, Verify install manifest, advisory gate, Copilot review request, rubberduck-gate) ran green too. `rubberduck-gate` reports "Gate skipped: non-squad-author" when the PR author is martinopedal directly - expected on solo runs.



## 2026-04-20T13-12-02Z - PR-2 (consumer-first README rewrite) #246, merged `e2d42d7`

Shipped PR-2: rewrote root README from 660 to 126 lines. First scroll = badges + value prop + install + 3 quickstart scenarios. Merged on first try, all 9 checks green.

**Key learnings:** Link constraints trump consolidated-plan suggestions. Em-dash gate applies to new content only, not historical entries. Worktree cleanup must run from the repo root, not from inside the worktree.

## 2026-04-20 - PR-3 (consumer-first restructure, items G/H/I/J/K)

PR #247, merged as `be665ea`. Built `Generate-ToolCatalog.ps1` (manifest-driven, idempotent, `-CheckOnly`) + 14 Pester tests. Generated tool-catalog docs. Wrote `operations.md` and `troubleshooting.md`. Added `tool-catalog-fresh` CI job.

**Key lesson:** Any Pester test invoking a script expected to exit non-zero MUST reset `$LASTEXITCODE` in `finally`/`AfterAll` or subsequent tests become victims of the leak.

## 2026-04-20 - Issue #252: PERMISSIONS.md split (PR #257, merged as 7b34e71)

Trimmed PERMISSIONS.md from 867 to 116 lines. 27 per-tool pages under `docs/consumer/permissions/`. Manifest-driven index via `Generate-PermissionsIndex.ps1`, gated by `permissions-pages-fresh` CI job.

**Key lessons:** `gh pr view --json mergeStateStatus` is the first check when "checks did not trigger" (DIRTY = silent conflict-suppression). Required check name is `Analyze (actions)` exactly, not the workflow-prefixed variant. Hybrid index (manifest for list, hand-curated for prose) works best for mixed content.


## 2026-04-20 - Issue #230 framework matrix

Implemented framework x tool coverage matrix in New-HtmlReport with click-to-filter, manifest frameworks[] source-of-truth, regenerated tool catalogs + permissions index, and added report tests (full suite 1294 pass / 5 skipped).

## 2026-04-20T21:28:04Z - Issue #232 CI/CD cost telemetry

Implemented GH Actions billing plus ADO pipeline consumption cost telemetry for v1.2.0 with two independent wrappers (Invoke-GhActionsBilling.ps1, Invoke-AdoConsumption.ps1), two normalizers (Normalize-GhActionsBilling, Normalize-AdoConsumption), manifest registration, fixtures, wrapper and normalizer tests, and permission docs (gh-actions-billing.md, ado-consumption.md).

Validation: full Invoke-Pester -Path .\\tests -CI passed with **1321 passed / 0 failed / 5 skipped** (baseline before work: **1307 passed**), plus manifest-driven docs regeneration (Generate-ToolCatalog.ps1, Generate-PermissionsIndex.ps1).

## 2026-04-22 - Triaged 7 orphan query JSON files (#318 -> PR #327)

PR #327 squash-merged at 9c6ab7d. All 7 orphans (3 `appinsights-*.json` + 4 `aks-rightsizing-*.json`) routed to fate (c) library: `git mv` into new `queries/library/` subfolder + README codifying the reference-catalog convention. CHANGELOG Unreleased / Changed entry added.

### Per-file fate
- `appinsights-slow-requests.json` -> (c) mirrors `` in `Invoke-AppInsights.ps1`
- `appinsights-dependency-failures.json` -> (c) mirrors ``
- `appinsights-exception-rate.json` -> (c) mirrors ``
- `aks-rightsizing-{missing-hpa,oomkilled,over-provisioned,under-provisioned}.json` -> (c) mirror `` in `Invoke-AksRightsizing.ps1`

### Why uniform (c)
Both wrappers ship complete inline KQL today. Files are hand-curated catalogs with operator-facing reference value (copy-paste into Log Analytics) and align 1:1 with shipped detections. Deletion would lose curation; wiring up is a refactor outside triage scope. `queries/library/` + README prevents the next audit from re-flagging them.

### Pester / CI
- 1349 passed / 0 failed / 5 skipped (expected baseline preserved).
- All 17 required checks green; `Analyze (actions)` green; mergeable=CLEAN.
- No Copilot review comments after ~3 min wait, mergeStateStatus CLEAN, squash-merged.

### Learnings
- **`git mv` triggers no test failure when the moved file is an orphan.** Confirms the audit hypothesis: if no wrapper reads the file, no test depends on its path. Useful as a fast smoke-test for "is this really an orphan?" -- mv to a sibling folder, run Pester, watch for surprises. Zero failures = true orphan.
- **Em-dash gate fires on README.md inside subfolders.** `rg -- "—"` recursively walks; need to scrub before commit even in newly-created subdirectories.
- **`gh pr merge --squash` from inside a worktree fails** with `'main' is already used by worktree at <root>`. Run merge from the repo root or from any path outside the worktree, OR pass `--repo`. Worktree cleanup also must run from repo root, never from inside the worktree (matches prior 2026-04-19 learning, now confirmed for the merge step too).
- **Two `Unreleased` sections in CHANGELOG.md.** `[1.2.0 - Unreleased]` is the active band; `[Unreleased]` below it is the older legacy band. Add new entries to the 1.2.0 band.
## 2026-04-22 - AzGovViz UI pattern research drop (decisions inbox)

Research-only task for Sentinel's HTML report rebuild. Wrote \.squad\decisions\inbox\atlas-azgovviz-ui-patterns.md.

### Learnings

- **AzGovViz HTML is single-file, no tab-strip.** Four stacked resizable panes (HierarchyMap / TenantSummary / DefinitionInsights / HierarchyTables), each its own <div> with a show/hide button and CSS background tint. The "tab" feel is a <button class="collapsible"> + <div class="content"> pattern per section.
- **Hierarchy tree is pure CSS**, not D3 / Mermaid: nested <ul><li> with ::before/::after connectors. ~40 lines of CSS, prints clean. Each node is a fixed-width <a> with dashed sides and rounded top, badges via <abbr title>, click jumps to #table_<id> anchors.
- **DataTables substitute is TableFilter (Max Guglielmi)** — vanilla JS, MIT, ~80KB, gives per-column dropdown filters, search box, CSV export, column show/hide, pagination, localStorage state. Better choice than jQuery DataTables for our self-contained HTML.
- **Severity is icon-only.** Body text is always #000 on tinted panes (AAA). Color is reserved for 9px FontAwesome glyphs. If we render severity as a text chip we must darken the AzGovViz palette (#ff0000 → #c00000, #67C409 → #3a7d0a) to clear AA.
- **Pane backgrounds:** white / #e0f2ff (sky) / #DAFFD1 (mint) / #EEEEEE (page). Sub-table accent #FFDF5C. Default-MG warning #FFCBC7.
- **Our wrapper drops a lot:** HierarchyMap.json (the MG ancestry), AzAdvertizer evidence URLs per policy/role, PrincipalDisplayName, PIM-eligible flag, ALZ Policy Version Checker, Orphan Resources, ClassicAdministrators. Most are additive parsers — no FindingRow contract change needed.
- **Big-picture report pick:** sticky top-bar of in-page anchor pills + single long scroll, not a JS tab strip. Preserves Ctrl+F + browser back-button while still giving AzGovViz's section structure.
- **Sources:** repo is JulianHayward/Azure-MG-Sub-Governance-Reporting (the JulianHayward/AzGovViz URL 404s — it's a redirect/alias). Demo: https://www.azadvertizer.net/azgovvizv4/demo/AzGovViz_demo.html. CSS bundle: zgovvizmain_004_047.css.


## 2026-04-22 - ALZ queries source-of-truth audit (decisions inbox)

Investigation-only task. Wrote `.squad/decisions/inbox/atlas-alz-queries-source-of-truth.md`.

### Findings
- `tools/tool-manifest.json:638` pins `upstream.repo` to `Azure/Azure-Landing-Zones-Library`, but that repo ships Bicep modules and policy JSON — **no ARG queries**. The pin is decorative / wrong artifact.
- `modules/Invoke-AlzQueries.ps1:59` already directs users to `martinopedal/alz-graph-queries` — wrapper docstring and `.copilot/copilot-instructions.md` already treat that repo as canonical. Manifest is the lone outlier.
- Local `queries/alz_additional_queries.json` vs upstream: **same** query count (206 total / 132 queryable) but **drifted** SHA-256 (~2 KB delta, likely whitespace + `queryIntent` field).
- `alz-graph-queries` ships much more than just the JSON: `Validate-Queries.ps1`, `Validate-KqlSyntax.ps1`, companion Graph/Cost/DevOps modules, Pester suites, ALZ checklist provenance files. It is a real upstream, not a scratchpad. 7 stars. Charter: *"ARG queries for ALZ checklist items missing automated validation"* — exact match for our `alz-queries` tool.

### File-ownership audit (15 files in `queries/`)
- `alz_additional_queries.json` → `Invoke-AlzQueries.ps1` (default param). ✅ consumed.
- `finops-*.json` (7 files) → `Invoke-FinOpsSignals.ps1:223` glob. ✅ consumed.
- `appinsights-*.json` (3 files) → **orphan**. `Invoke-AppInsights.ps1` has KQL inline.
- `aks-rightsizing-*.json` (4 files) → **orphan**. `Invoke-AksRightsizing.ps1` has KQL inline.

Verified by `rg "queries[\\/]appinsights-|queries[\\/]aks-rightsizing-"` returning zero hits outside `CHANGELOG.md` (the announcement entry).

### Recommendation: Path A (alz-graph-queries = canonical)
Smallest change, matches reality the wrapper already encodes. Two PRs proposed: (1) flip manifest `upstream.repo`, add `scripts/Sync-AlzQueries.ps1` + sync workflow + `alz-queries-fresh` docs-check job; (2) reorganize `queries/` into `queries/alz/` and `queries/finops/` subfolders.

### Learnings
- **Manifest `upstream.repo` can lie.** SHA-pinning at `Azure/Azure-Landing-Zones-Library` for a tool whose data lives at `martinopedal/alz-graph-queries` produced no test failure and no CI alarm — it just silently tracked the wrong artifact. Future audits: cross-check `tools/tool-manifest.json:upstream.repo` against what the wrapper actually reads, not just what the manifest declares.
- **`Get-ChildItem` glob ownership is invisible to grep.** `Invoke-FinOpsSignals.ps1` reads `finops-*.json` via `Get-ChildItem` so a file-name grep finds zero matches. To trace consumers, search both for the literal filename AND for the directory + glob pattern (`queries/finops-*` style).
- **Drift can preserve item count and still be real.** Same 206 / 132 counts, different bytes, different SHA. `Measure-Object` on parsed JSON is not a sufficient drift check; SHA-256 of the file is.
- **`gh api repos/<owner>/<repo>/contents/<path>` returns base64-encoded `content`** — useful for cheap README inspection without cloning. `[Convert]::FromBase64String` then `[System.Text.Encoding]::UTF8.GetString` decodes inline.
- **`[System.IO.Path]::GetTempFileName()` / `New-TemporaryFile` returns a path, not a directory** — appending `.json` then cleaning both is the safe pattern when you need a typed extension for `Get-FileHash`.
- **Orphan data files in a content folder are a real risk.** 7 of 15 files in `queries/` are written but never read. Worth a recurring sweep — anything in `queries/` whose filename prefix doesn't match a literal-or-glob hit in `modules/*.ps1` is a candidate for deletion or activation.
