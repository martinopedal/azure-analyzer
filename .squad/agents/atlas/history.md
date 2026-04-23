# Project Context

- **Owner:** martinopedal
- **Project:** azure-analyzer - Automated Azure assessment bundling azqr, PSRule, AzGovViz, and ALZ Resource Graph queries
- **Stack:** Python (orchestrator), KQL/ARG queries (JSON), PowerShell, GitHub Actions
- **Created:** 2026-04-15

## Core Context

Accumulated learnings from prior sessions (summarized 2026-04-22):

- ARG queries live in `queries/` as JSON, must return `compliant` boolean. All Azure tool invocations read-only (Reader role).
- `docs-check.yml` detection uses inline JS snippet with `ignoredPatterns` + `isDoc` predicate. After restructure: `docPathPatterns.some(p => p.test(f))`.
- Em-dash gate is zero-tolerance: `rg -- "-"` over every `.md` before commit. Applies to new content only, not historical entries.
- `git mv` + stub at old path defeats rename detection in `git status` (shows M+A not R); `git log --follow` still works.
- Parallel `git commit` calls collide on `index.lock` — always serialize.
- Authority limits trump sweep instructions — don't touch README/CHANGELOG if off-limits in the PR scope.
- Inbound-link search: exclude `.squad/agents/*/history.md`, `.squad/log/**`, `.squad/orchestration-log/**` (append-only logs, outdated paths are truth).
- Required check is `Analyze (actions)` (CodeQL). `rubberduck-gate` reports "Gate skipped: non-squad-author" on solo runs.
- Any Pester test invoking a script expected to exit non-zero MUST reset `$LASTEXITCODE` in `finally`/`AfterAll`.
- `gh pr view --json mergeStateStatus` is the first check when "checks did not trigger" (DIRTY = silent conflict-suppression).
- Worktree cleanup must run from the repo root, not from inside the worktree.

### Shipped PRs (2026-04-19 to 2026-04-20)

- **#182** (Issue #166) — ADO repo secret scanning + pipeline run-log correlation. Follow-ups: #197, #198, #199.
- **#243** (PR-1) — Consumer-first doc restructure: 9 doc moves under `docs/consumer/` + `docs/contributor/`, redirect stubs, `docs-check.yml` updates.
- **#246** (PR-2) — README rewrite 660→126 lines. Badges + value prop + install + quickstart.
- **#247** (PR-3) — `Generate-ToolCatalog.ps1` (manifest-driven, idempotent, `-CheckOnly`) + 14 Pester tests + `operations.md` + `troubleshooting.md` + `tool-catalog-fresh` CI job.
- **#257** (Issue #252) — PERMISSIONS.md split: 867→116 lines, 27 per-tool pages, `Generate-PermissionsIndex.ps1`, `permissions-pages-fresh` CI job.
- **Issue #230** — Framework x tool coverage matrix in `New-HtmlReport` with click-to-filter. Suite: 1294 pass / 5 skipped.
- **Issue #232** — GH Actions billing + ADO consumption cost telemetry (2 wrappers, 2 normalizers). Suite: 1321 pass / 5 skipped.

### 2026-04-22 - Report UX arc: AzGovViz deep-dive completed

- Brief merged to `decisions.md`. Architecture decision ratified: **single-page scroll with sticky anchor pills, no JS TabStrip.** AzGovViz ETL fix tracked as #307.
- Key wrapper gaps: `*_HierarchyMap.json` not parsed (blocks MG ancestry breadcrumbs), AzAdvertizer URLs dropped, PIM eligibility flag not extracted.
- CSS-only management-group tree adopted as a reusable primitive. TableFilter (vanilla JS, MIT) recommended over jQuery DataTables.
- Schema 2.2 contract locked with 13 new optional FindingRow fields (#299 umbrella issue).

## 2026-04-21 - azure-quota-reports wrapper viability research (decisions inbox)

Research-only. Wrote `.squad/decisions/inbox/atlas-azure-quota-reports-research.md`.

### Verdict
🟢 Implement as wrapper. Zero overlap with the 30 existing tools (grep for `quota` in `tool-manifest.json` returns nothing); closest neighbor WARA emits reliability advice but never enumerates `% quota used` per `(sub, region, sku)`. Repo is already PS 7 + `az` CLI + Reader-only — mirrors the `azure-cost` / `finops` / `defender-for-cloud` subscription-fanout pattern. Maps onto Schema 2.2 with no new fields (`Pillar='Reliability'`, new `Category='Capacity'`).

### Repo summary
`scripts/Get-AzureQuotas.ps1` — PS 7 + `az vm list-usage` + `az network list-usages` across subscription × location fanout. Four auth modes (CurrentSession default, Interactive, ServicePrincipal via env-var secret, ManagedIdentity). CSV out (`AzureQuotas_TIMESTAMP.csv` + `_errors.csv`), terminal warning table at default 80% threshold. Columns include `UsagePercent` — the natural `compliant` axis.

### Normalizer plan
One `FindingRow` per `(SubscriptionId, Location, Provider, QuotaId)`. `EntityType=Subscription` (bare-GUID canonical ID). Severity ladder Critical/High/Medium/Info at 99/95/80/below thresholds. `RuleId=azure-quota:{Provider}:{QuotaId}:{Location}`. `Properties` bag preserves `CurrentUsage`/`Limit`/`Unit`/`UsagePercent` for heatmap.

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

## 2026-04-23 - Track F Dependency Audit (READ-ONLY, no code edits)

**Deliverable:** `.copilot/audits/atlas-track-f-dependencies-2026-04-23.md` (13 KB).

**Summary:** All 6 hard dependencies (Tracks A/B/C/D/E/V) + Foundation **MERGED and FLESH-OUT COMPLETE** on main. Schema v2.2 + EdgeRelations enum (23 values) + Report Manifest tier picker production-ready. Track F skeleton frozen with 12 NotImplementedException-throwing functions in `AuditorReportBuilder.ps1`. 

**Verification:**
- Track A (722): ✅ FULL FLESH — AttackPathRenderer implemented (291 +/- lines), edge-collector wired into normalizers.
- Track B (720): ✅ FULL FLESH — ResilienceMapRenderer live, scaffold skips replaced.
- Track C (721): ✅ FULL FLESH — PolicyEnforcementRenderer + AlzMatcher (302 +/-) + AzAdvertizerLookup (158 +/-) + ALZ/AzAdvertizer catalogs.
- Track D (499): ⚠️ PARTIAL FLESH — Audit + top-3 enrichment landed; RemediationSnippets/DeepLinkUrl deferred under #491 (post-window). Acceptable deferral; fields default to empty. Report-manifest declares degradation.
- Track E (723): ✅ FULL FLESH — Triage scaffold complete with Copilot model ranking config, Viewer integration, 90+ new tests.
- Track V (467): ✅ FULL FLESH — Pode viewer loopback + cookie-auth + ReportManifest delegation.
- Foundation (456): ✅ FULL FLESH — Schema v2.2 (13 new optional fields, backwards-compat v2.1), EdgeRelations (23 values), synthetic fixtures (Phase 0 small/edge-heavy).

**Blockers:** None hard. Track D leg-2 deferral = opt-in enhancement; degradation declared.

**Conclusion:** ✅ READY TO IMPLEMENT. Open Track F implementation PR on #506. No schedule risk.

**Authority:** Squad approval pending; recommendation: proceed.

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
### Follow-ups proposed (4 issues)
1. Wrapper `Invoke-AzureQuotas.ps1` (vendor or fork, retry+timeout+sanitize, parallel runspaces).
2. `Normalize-AzureQuotas` with severity ladder + Capacity category.
3. Manifest registration + permissions page + CHANGELOG.
4. Lower-priority: migrate to unified `Microsoft.Quota` RP for broader provider coverage.
5. Lower-priority: add Capacity heatmap lane (Subscription × Region) to the unified report.

### Learnings
- **`az vm list-usage` / `az network list-usages` is the legacy quota surface.** The unified `Microsoft.Quota` RP (`az quota`) supersedes it and would broaden coverage (Storage, AppService, Logic Apps), but Reader is enough for reads on either path. Worth a follow-up issue, not a blocker for v1.
- **Reservations / Capacity Reservations are a distinct API** (`Microsoft.Capacity`) — explicitly out of scope for any quota wrapper. Note in docstring to prevent scope creep.
- **`grep "quota" tools/tool-manifest.json` is a fast gap-test.** Zero hits = clean greenfield. Same trick worked for the ALZ queries audit.

## 2026-04-22 - ALZ queries source-of-truth audit (decisions inbox)

Investigation-only task. Wrote `.squad/decisions/inbox/atlas-alz-queries-source-of-truth.md`.

### Issues filed: #314–#319 (ALZ-graph-queries Path A migration)

Filed 6 issues for the `alz-queries` upstream realignment:
- #314 fix manifest `upstream.repo`, #315 sync script, #316 CI drift detection, #317 folder reorg, #318 orphan query cleanup, #319 docs update.
- Dependency chain: #314 → #315 → #316; #317/#318 independent.

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
- 2026-04-21 — IaCFile EntityType (schema + EntityStore dedup contract) now available for IaC normalizers to use. Canonical ID: `iacfile:{repo-slug}:{relative-path}` (e.g., `iacfile:github.com/org/repo:terraform/main.tf`). Enables cross-tool file-level dedup when terraform-iac, Trivy, Checkov, and tfsec report findings on the same IaC file. Migration of terraform-iac normalizer from EntityType=Repository to IaCFile deferred to follow-up. PR #423 (SHA 5577bd77).
- **Orphan data files in a content folder are a real risk.** 7 of 15 files in `queries/` are written but never read. Worth a recurring sweep — anything in `queries/` whose filename prefix doesn't match a literal-or-glob hit in `modules/*.ps1` is a candidate for deletion or activation.

## 2026-04-22 - Filed issues for azure-quota-reports (5-issue chain)

**2026-04-21T10:32:34Z:** Verdict ratified by Martin. Issues filed post-approval:

### Azure-Quota-Reports Issues (5-issue chain)
- #321 — feat: register azure-quota-reports tool in tool-manifest.json — https://github.com/martinopedal/azure-analyzer/issues/321
- #322 — feat: add modules/Invoke-AzureQuotaReports.ps1 wrapper — https://github.com/martinopedal/azure-analyzer/issues/322  *(depends on #321)*
- #323 — feat: add modules/normalizers/Normalize-AzureQuotaReports.ps1 — https://github.com/martinopedal/azure-analyzer/issues/323  *(depends on #322)*
- #324 — feat: tests for azure-quota-reports wrapper + normalizer (with fixture) — https://github.com/martinopedal/azure-analyzer/issues/324  *(depends on #323)*
- #325 — docs: add azure-quota-reports to README + PERMISSIONS.md + CHANGELOG.md + tool catalog regen — https://github.com/martinopedal/azure-analyzer/issues/325  *(depends on #324)*

**Decision ratified:** `compliant = (UsagePercent < 80%)`, `EntityType=Subscription`, `Pillar='Reliability'`, `Category='Capacity'`. Schema 2.2 ready (no new fields required). Full schema mapping locked in research brief + issue descriptions.

## 2026-04-21 - Issue #317 queries/ reorg into per-tool subfolders (PR #335)

Reorganized `queries/` runtime catalogs into per-tool subfolders matching their owning wrapper. Goal: kill the flat-folder layout that mixed alz + finops + library at the top, and make wrapper ownership self-evident in the file tree.

### Layout call

- `queries/alz/alz_additional_queries.json` (sole reader: `Invoke-AlzQueries.ps1`; sole writer: `scripts/Sync-AlzQueries.ps1`).
- `queries/finops/finops-*.json` (7 files, sole reader: `Invoke-FinOpsSignals.ps1` via `Get-ChildItem -Filter 'finops-*.json'`).
- `queries/library/` unchanged - 8 reference-only files mirroring inline-wrapper KQL, no wrapper reads them. Subdivision deferred (too small to justify nesting).
- New `queries/README.md` codifies the convention so future tools (e.g. azure-quota) know where to drop their catalog.

### Process notes

- 3-of-3 rubber-duck APPROVE before implementation (Opus 4.6 + GPT-5.3-codex + Goldeneye); Goldeneye and GPT both flagged downstream doc references I'd missed (`README.md`, `docs/consumer/permissions/finops.md`, `queries/library/README.md`) - fixed in same commit.
- All 8 moves via `git mv` so blame survives. `git status -R` confirms rename detection.
- Pester baseline preserved: **1354 passed / 0 failed / 5 skipped** (same as pre-PR).
- Test fix subtlety: `Sync-AlzQueries.Tests.ps1` DryRun test seeded an `old-content` file at the destination to force a `WouldUpdate` action - moving the destination to `queries\alz\` meant the seed had to move too, otherwise the test would have flipped to `WouldCreate` and silently passed for the wrong reason.
- `markdown-link-check` failed once on a flaky TLS handshake to `https://keda.sh/` (unrelated external link). Per resilience contract: re-ran failed job, second run green.
- No Copilot review comments came back; merged at `b8aa059` with squash + `--delete-branch --admin`.

### Wrapper-glob ownership stays invisible to grep

Reinforced the lesson from the orphan-query audit: `Invoke-FinOpsSignals.ps1` reads its catalogs via a directory glob (`Get-ChildItem -Filter 'finops-*.json'`), so a literal-filename grep returns zero hits. Per-tool subfolders make this ownership visible in the tree, which is the durable fix.
## 2026-04-23 - Sample regeneration framework (Issue #906 → PR #924)

**Deliverable:** Sample regeneration framework with drift detection.

**Scope:**
- ✅ Created `scripts/Regenerate-Samples.ps1` — regenerates `samples/` from fixtures against current FindingRow v2.2 schema + renderers (HTML/MD)
- ✅ Created `tests/fixtures/synthetic-multi-tool.json` — multi-tool fixture covering 5 tools (azqr, prowler, maester, gitleaks, trivy) across Azure/Entra/GitHub scopes
- ✅ Regenerated `sample-findings-v2.json` (v2.2 FindingRow array), `sample-entities.json` (v3 entity store), `sample-report-v2-mockup.html`, `sample-report-v2-mockup.md`
- ✅ Created `samples/PROVENANCE.md` — fixture → output mapping + repro command documentation
- ✅ Created `tests/samples/SampleDrift.Tests.ps1` — drift-detection canary that re-renders HTML/MD and diffs against committed outputs; runs in CI to catch renderer changes without sample updates

**Motivation:** Per Sage B3 + GPT-5.4 breadth audit dimension #7: outdated `samples/` broke operator demos. Sample reports must reflect current schema (FindingRow v2.2 + EntityStore v3) and renderer output (HTML/MD/Exec dashboard).

**Key challenges:**
1. File persistence across branch switches — resolved by atomic creation + commit in single PowerShell invocation
2. Synthetic fixture design — 5 tools covering multiple scopes (Azure/Entra/GitHub) with realistic findings
3. Drift test normalization — strip timestamps before diff to avoid false positives

**PR:** https://github.com/martinopedal/azure-analyzer/pull/924  
**Issue:** https://github.com/martinopedal/azure-analyzer/issues/906  
**Commit:** 2d4f346

**Learnings:**
- Tool file creation doesn't persist across interactive branch switches — must commit changes in same invocation that creates them
- Synthetic fixtures should demonstrate v2.2 schema additions (Pillar, Impact, Effort, Frameworks)  
- Drift tests need timestamp normalization to avoid false failures on identical content with different generation times
- Git's `index.lock` issues require atomic operations or explicit serialization of git commands

## 2026-04-22 - Issue #299 Schema 2.2 additive bump (PR #343, merged at 97b8277)

Foundational schema work. Bumped New-FindingRow to Schema 2.2: 13 new optional fields with zero-value defaults (Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, ScoreDelta, MitreTactics, MitreTechniques, EntityRefs, ToolVersion). Two new union-merge helpers (Merge-FrameworksUnion, Merge-BaselineTagsUnion) in EntityStore.ps1. Backward-compatible: existing callers get the same row shape plus zero-value new fields.

### Acceptance
- Baseline 1369 / 0 / 5 -> 1381 / 0 / 5 (+12 new tests across 	ests/shared/Schema.Tests.ps1 and 	ests/shared/EntityStore.Tests.ps1).
- 17 test files mechanically updated for '2.1' -> '2.2' literal version assertions; zero behavioural coverage modified.
- All 17 required checks green; `Analyze (actions)` green; squash-merged via --auto after main settled.
- Decision file: .squad/decisions/inbox/atlas-schema-22.md (locked parameter names + downstream guidance for #300-#313).

### Unblocks
14 per-tool ETL closures: #300 (azqr), #301 (PSRule), #302 (Defender), #303-#304 (TBD slots), #305 (Maester), #306 (Kubescape), #307 (AzGovViz), #308 (WARA), #309 (Sentinel Incidents), #310 (Sentinel Coverage), #311 (Trivy), #312 (Infracost), #313 (Scorecard).

### Learnings
- **CHANGELOG.md is a hot conflict file during fast-moving days.** Three rebase cycles in this PR alone, each with the same 1-line `### Added` collision against a sibling PR. Resolve by hand-keeping both lines (additive). Faster than `gh pr merge --auto` + waiting for the queue when main is churning at >1 PR / 5 min.
- **gh pr merge --admin --auto is rejected** on this repo (mutually exclusive flags). Use `--auto` alone (drops admin override) or sit on the PR until checks green and use `--admin --squash` directly.
- **The dit tool silently no-ops on malformed old_str** (whitespace mismatch from a here-string). Mitigation: always `rg "<<<<<<<"` after a programmatic conflict resolution before `git add`.
- **Bumping $script:SchemaVersion is impossible without touching test literal assertions.** The "no test modification" rule cannot apply to literal version strings (`Should -Be '2.1'`); the mechanical sweep is the minimum-invasive interpretation. Document this explicitly in the PR body so reviewers don't bounce it.
- **Frameworks was already declared in v2.1** as `[object[]]`. Kept the loose type to preserve back-compat for fixtures that pass mixed shapes; documented in the decision file that the *contract* is hashtable-shaped. `Merge-FrameworksUnion` works against either shape.
- **No Copilot review comments** in the 8-min wait window — second confirmation (after #318) that on schema-only changes Copilot tends to skip. Squash-merge is permitted per the cloud-agent PR review contract when zero open threads.

## 2026-04-23 - Manifest audit (read-only) — atlas-manifest-audit-2026-04-23.md

**Task:** Audit `tools/tool-manifest.json` (single source of truth for tool registration) against codebase reality. Deliverable: `.copilot/audits/atlas-manifest-audit-2026-04-23.md` (~12 KB markdown report).

### Summary
✅ **PASS — Zero drift.** 37 manifest entries (32 tools + 4 vendored JS deps + 1 prerequisite) audit clean:
- **Wrappers:** 36/37 match manifest scripts, 1 intentional orphan (`Invoke-CopilotTriage.ps1`, `enabled: false` by design).
- **Normalizers:** 36/36 match manifest normalizer entries (0 orphans).
- **Install blocks:** 37/37 allow-list compliant (11 CLI installs use approved managers winget/brew/pipx; 21 psmodule; 4 "none"; 1 gitclone to github.com).
- **Duplicate names:** 0 (no silent-select risk).
- **Report blocks:** 37/37 complete (color + label present).

### Three deferred findings (P2)
1. **Copilot Triage orphan documentation** — design is intentional but undocumented. Quick fix: add inline comment to manifest entry.
2. **Azure Quota forward-pending** — wrapper/normalizer stubs registered but implementation pending (#322–#325). Zero impact to current audits.
3. **ADO tools lack source field** — 4 ADO tools (ado-connections, ado-consumption, ado-pipeline-correlator, ado-repos-secrets) missing `source` field. 33/37 pattern would be improved by backfill; doesn't block anything.

### Key validation tactics
- **Reverse orphan check:** All 37 wrapper files matched to manifest `script` field (no missed registrations).
- **Normalizer coverage:** 36/36 files matching manifest `normalizer` names (cope-trial per-design null is expected).
- **Allow-list sweep:** Checked all install blocks for disallowed managers / clone hosts (passed).
- **Report field completeness:** Each tool has `report.color` (hex) + `report.label` (display name) — necessary for renderers that iterate manifest dynamically.
- **Manifest completeness:** All 32 enabled tools have `enabled: true`, `provider`, `scope`, `normalizer`, and `script` fields (no sparse records).

### Upstream implications
- ALZ queries audit (#319 + PR #335): Queries reorganization validated via file-ownership sweep; zero fallout in manifest.
- Azure Quota implementation chain (#321–#325): Stubs are registration-ready; normalizer tests framework and fixture structure align with 30 existing tools.
- Track F / report-manifest.json writer (future): Manifest has all required metadata (source, label, color, phase, provider, scope); 4-field ADO backfill would perfect the pattern but is not blocking.

### Learnings
- **Manifest `upstream.repo` can point to the wrong artifact** — confirmed by ALZ queries audit (manifest said Azure/Azure-Landing-Zones-Library, wrapper reads martinopedal/alz-graph-queries). A forward audit should cross-check `upstream.repo` against what the wrapper actually reads / clones.
- **`enabled: false` entries still have wrappers on disk** — expected; design allows opt-in tools to be shipped but dormant. Normalizer is skipped (null), which is correct.
- **Single-source-of-truth manifest works when locked down** — no CLI-generated tool-registration (everything is hand-curated JSON), no dual systems, no divergence risk. The 0-orphan normalizer count and 37-match wrapper count confirms the locked architecture.

### Audit output
Wrote `.copilot/audits/atlas-manifest-audit-2026-04-23.md` (11.8 KB). Full-boilerplate table of 37 entries with file-existence checks, install/report block validation, and per-finding PR title recommendations.
