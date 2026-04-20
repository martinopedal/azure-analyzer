# Lead - Doc + Repo Restructure Research (consumer-first)

**Author:** Lead
**Date (UTC):** 2026-04-20T12:17:33Z
**Gating directive:** `.squad/decisions/inbox/coordinator-doc-restructure-consumer-first-2026-04-20T13-35-46Z.md`
**Status:** Research only - no code/file moves performed. Decomposition into issues for execution after PRs #219 / #221 / #222 merge.

---

## 1. Current state audit

### Root-level docs (all in `C:\git\azure-analyzer\`)

| File | LOC | Audience | Notes |
|---|---|---|---|
| `README.md` | 493 lines, ~54 KB | **Mixed (consumer-heavy, but bloated)** | Currently the only consumer entry point. Quickstart is at line 9 (good), but consumer scrolls past 30+ headings before hitting `Permissions` (line 607). 8 “Scenario” blocks, full param table, full 26-tool table, both schemas, PR review-gate notes, contributor section all inline. |
| `CHANGELOG.md` | ~135 KB | Consumer | Standard. Stays at root. |
| `LICENSE` | 1 KB | Consumer | Stays at root. |
| `PERMISSIONS.md` | ~45 KB | Consumer | Required reading before run. Stays at root (or `docs/consumer/`). |
| `SECURITY.md` | 1 KB | Consumer | GitHub-recognised location. Stays at root. |
| `THIRD_PARTY_NOTICES.md` | 6.5 KB | Consumer (compliance) | Stays at root. |
| `CONTRIBUTING.md` | 3 KB | **Contributor** | GitHub-recognised location - must stay at root, but content can shrink and link to `docs/contributor/`. |
| `AI_GOVERNANCE.md` | 0.5 KB | **Contributor** | Project-policy doc. Move to `docs/contributor/` or fold into CONTRIBUTING. |
| `pester.log`, `retry.log`, `testResults.xml` | - | **Build artefacts** | Should never be committed at root. `.gitignore` cleanup item. |
| `report-template.html` | ~40 KB | Internal (report renderer asset) | Used by `New-HtmlReport.ps1`. Move to `templates/` or `assets/`. |
| `Invoke-AzureAnalyzer.ps1`, `New-HtmlReport.ps1`, `New-MdReport.ps1`, `New-ExecDashboard.ps1` | - | Public functions exported by the module | Stay at root (referenced by `AzureAnalyzer.psm1` line 33). Moving them requires manifest + psm1 updates. |
| `AzureAnalyzer.psd1`, `AzureAnalyzer.psm1` | - | **Module manifest (THE consumable artefact)** | Stay at root. |

### `docs/` tree

| File | Audience | Notes |
|---|---|---|
| `docs/ARCHITECTURE.md` (17 KB) | **Contributor** | ETL pipeline, dual data model, plugin model. Pure internals. |
| `docs/CONTRIBUTING-TOOLS.md` (12 KB) | **Contributor** | Five-step recipe to add a new tool. Companion to CONTRIBUTING.md. |
| `docs/continuous-control.md` (27 KB) | **Consumer (advanced)** | OIDC + Function App walkthrough. Linked from README §“Continuous Control mode”. |
| `docs/sinks/log-analytics.md` (3.5 KB) | **Consumer (advanced)** | DCR / Logs Ingestion API setup. Linked from README §“Output sinks”. |
| `docs/ai-triage.md` (5 KB) | **Consumer (optional feature)** | `-EnableAiTriage` documentation. |
| `docs/gitleaks-pattern-tuning.md` (1.4 KB) | **Consumer (advanced)** | `-GitleaksConfigPath` for ADO scans. |
| `docs/future-iac-drift.md` (7.6 KB) | **Contributor / proposal** | Phase A live; Phase B-E design notes. |
| `docs/proposals/copilot-triage-panel.md` (28 KB) | **Contributor (proposal/RFC)** | Sage design proposal, draft. |

### `.github/`, `.squad/`, `.copilot/`

All pure contributor / squad-automation. Already excluded from archives via `.gitattributes` (`.squad/** export-ignore`, `.github/workflows/squad-*.yml export-ignore`, `.github/agents/ export-ignore`). Not in scope for the user-facing restructure.

### Top-level dirs reviewed

`modules/`, `modules/shared/`, `modules/normalizers/`, `modules/reports/`, `modules/sinks/`, `modules/iac/`, `queries/`, `samples/`, `scripts/`, `templates/`, `tests/`, `tools/`, `azure-function/`, `infra/`, `hooks/`, `output*/`. The only dirs touched by this restructure are the doc surface (`docs/`) and root-level markdown / template assets. `output*/` (5 dirs) are run artefacts polluting the root listing - separate `.gitignore` hygiene item.

---

## 2. Consumer journey (today)

A fresh user wanting to *consume* azure-analyzer as a module:

1. **Discover.** Lands on the GitHub repo. Reads `README.md`. **Friction:** there is no PSGallery publish (`AzureAnalyzer.psd1` has no `PrivateData.PSData` block, no `Repository`/Tags). Consumption today is **clone-and-import**, not `Install-Module`. README does not state this contract until line ~14.
2. **Install.** Runs `git clone …; cd azure-analyzer`. **Friction:** README §“Quick Start” at line 9 launches into 8 scenarios spanning 80 lines before the user sees `Connect-AzAccount` semantics or that they need PowerShell 7.4. Prereq table is at line 319.
3. **Invoke.** `.\Invoke-AzureAnalyzer.ps1 -SubscriptionId …`. **Friction:** the README headlines the *script* (`.\Invoke-AzureAnalyzer.ps1`) rather than the *module* (`Import-Module .\AzureAnalyzer.psd1; Invoke-AzureAnalyzer -SubscriptionId …`). The psm1 explicitly comments “local module for convenience” - this is the actual consumption surface and is invisible in README.
4. **Interpret output.** README §“What you get” is at line 173. Schema reference at line 547. **Friction:** the user has to scroll past 5 “Scenario” blocks, the entire prereq+install matrix, full param table, and the 26-tool table to learn what `output/report.html` contains.
5. **Operate at scale (advanced).** Multi-tenant fan-out, incremental, sinks, continuous control, AI triage all live in README plus 4 separate `docs/` pages. **Friction:** none of these are progressive disclosure - they sit inline in the same scroll as the basic Quick Start.
6. **Contribute (out of scope for consumer).** `CONTRIBUTING.md` cleanly redirects to `docs/CONTRIBUTING-TOOLS.md`. Decent. But README §“Architecture & contributor docs” (line 313) and §“PR review gate behavior” (line 625) are noise for a consumer.

**Top friction points:**
- A. README is **493 lines** and conflates consumer + contributor + internal-RFC content.
- B. **Module-style consumption (`Import-Module`)** is not documented. The script-style (`.\Invoke-AzureAnalyzer.ps1`) dominates every code block.
- C. **Prereqs (line 319) and Permissions (line 607)** are below most operational examples - users hit auth errors before reading them.
- D. No `docs/consumer/` index; advanced consumer pages (`continuous-control`, `sinks`, `ai-triage`, `gitleaks-tuning`) are scattered alongside contributor pages (`ARCHITECTURE`, `CONTRIBUTING-TOOLS`, `proposals/`).
- E. **PSGallery story is missing.** Users expect `Install-Module AzureAnalyzer` for a module called "AzureAnalyzer". → see Open Questions §8.

---

## 3. Proposed doc restructure (file moves)

Goal: split `docs/` into `docs/consumer/` (advanced consumer how-tos) and `docs/contributor/` (developer/contributor reference). Root keeps GitHub-recognised files only.

### Moves

| Source | Destination | Rationale |
|---|---|---|
| `docs/continuous-control.md` | `docs/consumer/continuous-control.md` | Advanced consumer how-to (deploy as scheduled control). |
| `docs/sinks/log-analytics.md` | `docs/consumer/sinks/log-analytics.md` | Consumer setup for output sink. |
| `docs/ai-triage.md` | `docs/consumer/ai-triage.md` | Consumer-facing optional feature. |
| `docs/gitleaks-pattern-tuning.md` | `docs/consumer/gitleaks-pattern-tuning.md` | Consumer config knob for ADO scans. |
| `docs/ARCHITECTURE.md` | `docs/contributor/ARCHITECTURE.md` | Internal pipeline/data model. |
| `docs/CONTRIBUTING-TOOLS.md` | `docs/contributor/adding-a-tool.md` | Renamed for clarity; contributor-only. |
| `docs/future-iac-drift.md` | `docs/contributor/proposals/iac-drift.md` | Active proposal/design doc; co-locate with other proposals. |
| `docs/proposals/copilot-triage-panel.md` | `docs/contributor/proposals/copilot-triage-panel.md` | Already a proposal - move into contributor proposals tree. |
| `AI_GOVERNANCE.md` (root) | `docs/contributor/ai-governance.md` | Project policy, contributor-relevant. Append a one-line link from `CONTRIBUTING.md`. |
| `report-template.html` (root) | `templates/report-template.html` | Internal renderer asset; root pollution. Update `New-HtmlReport.ps1` path. |

### New root-level additions

| New file | Purpose |
|---|---|
| `docs/consumer/README.md` | Index: Quickstart shortcut → install → invoke → interpret → advanced (with links to each consumer doc). |
| `docs/contributor/README.md` | Index: how to add a tool, architecture, proposals, squad pointers. |
| `docs/README.md` (or rely on GitHub auto-render of `docs/`) | Top-level switcher: “Consumer docs ↗ / Contributor docs ↗”. |

### Stays at root (non-negotiable)

`README.md`, `LICENSE`, `SECURITY.md` (GitHub recognises), `CHANGELOG.md`, `THIRD_PARTY_NOTICES.md`, `CONTRIBUTING.md` (GitHub recognises), `PERMISSIONS.md` (heavy reference, frequently linked), `AzureAnalyzer.psd1`, `AzureAnalyzer.psm1`, `Invoke-AzureAnalyzer.ps1`, `New-HtmlReport.ps1`, `New-MdReport.ps1`, `New-ExecDashboard.ps1`.

### Cleanup (separate atomic items)

- Remove committed build artefacts from root: `pester.log`, `retry.log`, `testResults.xml` → `.gitignore` and `git rm`.
- Add `output/`, `output-*/` to `.gitignore` if not already (currently 5 such dirs at root, polluting the listing). Verify CI doesn't depend on the path.

---

## 4. Proposed repo restructure (only if needed)

The directive says: change layout *only if* it materially improves module consumption.

**Assessment:** The biggest consumption friction is **discovery via PSGallery**, not the file layout. The current root layout (`AzureAnalyzer.psd1` + `.psm1` + 4 public-function `.ps1` files at root + `modules/` for internals) is **standard and correct** for a clone-and-import module. Moving them into `src/` would only complicate `Import-Module` for cloners and force a rev to `RootModule`/manifest paths.

**Recommendation: do NOT restructure source layout.** The wins are not worth the breakage of every existing PR, link, and CI script. Two small, safe moves to consider:

1. **`report-template.html` → `templates/`** (covered above; not a structural change, just cleaner).
2. **Optional, low-priority:** create a `docs/consumer/install.md` that documents the *future* PSGallery path side-by-side with the current clone-and-import path, so README can collapse the install section to a 5-line hand-off. Don't actually publish to PSGallery in this stream of work - that's a separate decision (see §8).

If/when PSGallery publish lands (out of scope here), then a `src/` reshuffle would be worth revisiting. Today: not warranted.

---

## 5. README.md rewrite plan

Target: a consumer hits **Install + Quickstart in the first scroll** (≤ ~80 lines), with everything else linked out.

### New section order (proposed)

1. **Title + 1-paragraph elevator pitch** (~5 lines). Drop the giant 26-tool inline list - link to `docs/consumer/tools.md`.
2. **Install (2 paths):** clone-and-import (today’s reality) + PSGallery placeholder. ≤ 15 lines.
3. **Quickstart (3 canonical scenarios, not 8):** Azure-only, Azure+Identity, Azure+Repo. Each 4 lines. The 5 advanced scenarios (GHEC, ADO, Sentinel, multi-tenant, local-CI) move to `docs/consumer/scenarios.md`.
4. **What you get** (the existing output table - keep, it’s short and useful).
5. **Permissions at a glance** (5-line summary table) → link to `PERMISSIONS.md`.
6. **Advanced** (one bulleted index of links, no prose):
   - Multi-tenant fan-out → `docs/consumer/multi-tenant.md` (extract from current README §“Scenario 8”).
   - Incremental & scheduled scans → `docs/consumer/incremental.md`.
   - Continuous Control mode → `docs/consumer/continuous-control.md`.
   - Output sinks (Log Analytics) → `docs/consumer/sinks/log-analytics.md`.
   - AI triage → `docs/consumer/ai-triage.md`.
   - Custom installer config → `docs/consumer/install-config.md`.
   - Tool catalog (all 26) → `docs/consumer/tools.md`.
   - Schema reference (results.json + entities.json) → `docs/consumer/schema.md`.
7. **Contributing** (3 lines) → `CONTRIBUTING.md` + `docs/contributor/`.
8. **License + Attribution** → links to `LICENSE`, `THIRD_PARTY_NOTICES.md`.

### What gets removed/relocated from current README

- Lines ~9–127 (Quick Start with 8 scenarios, manifest installer prose, install-config schema) → split between §“Quickstart” (3 scenarios) and `docs/consumer/install-config.md`.
- Lines ~155–171 (Continuous Control prose, including a duplicated paragraph) → `docs/consumer/continuous-control.md`.
- Lines ~194–311 (HTML report features, Markdown report features, drift, portfolio screenshots) → `docs/consumer/reports.md`.
- Lines ~313–317 (“Architecture & contributor docs”) → deleted from README; consumers don’t need it.
- Lines ~406–442 (full parameter table) → `docs/consumer/parameters.md`.
- Lines ~457–506 (Scoped Runs huge table, Incremental scans) → `docs/consumer/scoped-runs.md` and `docs/consumer/incremental.md`.
- Lines ~508–545 (the 26-tool catalog table) → `docs/consumer/tools.md`.
- Lines ~547–605 (schema reference) → `docs/consumer/schema.md`.
- Lines ~625–628 (PR review gate behavior) → `docs/contributor/pr-review-gate.md` (it’s entirely contributor info).
- Lines ~631–633 (Roadmap) → keep at root, but trim to ≤ 3 bullets.

**Length target:** new `README.md` ≤ 200 lines (down from 493).

---

## 6. Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| **Broken inbound links.** Existing PRs/issues/CHANGELOG entries link to `docs/ARCHITECTURE.md`, `docs/CONTRIBUTING-TOOLS.md`, `docs/continuous-control.md`, `docs/sinks/log-analytics.md`, `docs/ai-triage.md`, `docs/gitleaks-pattern-tuning.md`. | High | Medium | First-class **link-redirect stub** issue (see §7 item L). Each old path becomes a stub file containing only `Moved to: <new path>` + an HTML `<meta http-equiv="refresh">` so GitHub-rendered pages auto-redirect. Keep stubs for 1 minor version, then delete. |
| **CHANGELOG impact.** All historical CHANGELOG entries reference the old paths. | High | Low | Don’t rewrite history. Stubs cover the lookup. Add a single CHANGELOG note announcing the restructure with both old and new paths. |
| **PSGallery / manifest impact.** `AzureAnalyzer.psd1` references `Invoke-AzureAnalyzer.ps1`, `New-HtmlReport.ps1`, `New-MdReport.ps1` at root via `AzureAnalyzer.psm1`. Moving any of those breaks `Import-Module`. | High | High | **Do not move** the four `.ps1` public functions or the manifest in this work stream. Only move `report-template.html` (referenced by `New-HtmlReport.ps1` - must update path constant in same PR). |
| **Contributor onboarding impact.** Squad agents (Atlas/Sage/Forge/Sentinel) and Ralph dispatch use `.squad/` paths and CONTRIBUTING. New contributors land on README first. | Medium | Low | The new README contributing section explicitly directs to `CONTRIBUTING.md` → `docs/contributor/`. Update `.copilot/copilot-instructions.md` references if they hard-code `docs/ARCHITECTURE.md` or `docs/CONTRIBUTING-TOOLS.md`. |
| **`.gitattributes` / CODEOWNERS impact.** `.gitattributes` lists `.squad/`, `.github/workflows/squad-*.yml`, `.github/agents/` as `export-ignore`. CODEOWNERS exists. Neither references the docs that are moving. | Low | Low | Verify CODEOWNERS doesn’t glob `docs/**`; if it does, add entries for `docs/consumer/**` and `docs/contributor/**`. |
| **`tool-manifest.json` paths.** Verified manifest `install.path` etc. is for tool installs, not docs. No risk. | Low | None | None. |
| **Workflow path filters.** `docs-check.yml`, `ci.yml` may path-filter on `docs/**` or specific files. | Medium | Medium | Audit workflows for hard-coded `docs/CONTRIBUTING-TOOLS.md` or `docs/ARCHITECTURE.md` paths. Update filters. |
| **Hooks path filters.** `hooks/` directory contains repo hooks; pre-commit hook installer references `tools/Install-PreCommitHook.ps1` not docs. | Low | None | None. |
| **Search engine + bookmarks.** External bookmarks, blog posts pointing at GitHub `blob/main/docs/ARCHITECTURE.md`. | Medium | Low | Stub redirects + retain stubs through the next minor release. |
| **Open PRs (#219, #221, #222) touch reports/UX.** Restructure cannot land until they merge. | High (merge-conflict) | Medium | Per coordinator directive, **gate this work** until those merge. Lead reconfirms before kicking off. |

---

## 7. Decomposition into work items

All issues prefixed `docs:` or `chore:`, labelled `squad`, scoped atomic. Owners are squad agents.

| # | Title | 2-line description | Owner | Depends on |
|---|---|---|---|---|
| A | `docs: split docs/ into docs/consumer/ and docs/contributor/` | File-move-only PR. Moves the 8 docs files per §3 table. No content rewrite. | **Atlas** | none |
| B | `docs: add link-redirect stubs at old docs paths` | For each moved file, leave a 5-line stub at the old path: H1 + “Moved to <new>” + meta-refresh. | **Atlas** | A |
| C | `chore: move report-template.html into templates/` | Move `report-template.html` to `templates/report-template.html`. Update path constant in `New-HtmlReport.ps1` and any test fixture. Validate Pester report tests still pass. | **Forge** | none |
| D | `chore: gitignore root build artefacts` | `git rm` `pester.log`, `retry.log`, `testResults.xml`. Add to `.gitignore`. Add `output*/` glob if absent. | **Sentinel** | none |
| E | `docs: relocate AI_GOVERNANCE.md to docs/contributor/` | Move + add a one-liner pointer from `CONTRIBUTING.md`. | **Atlas** | A |
| F | `docs: rewrite README.md as consumer-first landing` | Per §5 plan: ≤ 200 lines, install + 3-scenario quickstart in first scroll, all advanced content as link index. | **Atlas (drafts), Lead reviews)** | A, B, G–K (so target pages exist) |
| G | `docs: extract advanced scenarios → docs/consumer/scenarios.md` | Pull GHEC, ADO, Sentinel, multi-tenant, local-fallback scenarios out of README. | Atlas | A |
| H | `docs: extract reports walkthrough → docs/consumer/reports.md` | HTML/MD report features, drift detection, portfolio mode. | Atlas | A |
| I | `docs: extract tool catalog → docs/consumer/tools.md` | The 26-row tool table + per-tool notes. Generated-or-handwritten? Note: `tool-manifest.json` is single source of truth - see §8. | Atlas + Sage (for manifest-driven generation question) | A |
| J | `docs: extract schema reference → docs/consumer/schema.md` | results.json v1, entities.json v3, FindingRow v2 tables. | Atlas | A |
| K | `docs: extract install-config + parameters → docs/consumer/{install-config,parameters,scoped-runs,incremental}.md` | Four small consumer reference pages. | Atlas | A |
| L | `docs: add docs/consumer/README.md and docs/contributor/README.md indexes` | Two short index pages so the new dirs render cleanly on GitHub. | Atlas | A |
| M | `docs: add module-consumption section (Import-Module path)` | Document the `Import-Module .\AzureAnalyzer.psd1; Invoke-AzureAnalyzer …` flow as the canonical consumption surface. Currently absent. | Atlas | F |
| N | `chore: audit and update inbound link references` | Sweep `.copilot/copilot-instructions.md`, workflows (`docs-check.yml`), CODEOWNERS, CHANGELOG.md (forward-looking note only) for stale paths. | Sentinel | A, B |
| O | `docs: relocate PR review-gate notes from README → docs/contributor/pr-review-gate.md` | Pure contributor content; no consumer value at root. | Atlas | A, F |
| P | `chore: update CHANGELOG.md with the restructure announcement` | Single entry under unreleased, listing old→new path map for the top-linked docs. | Lead | All others |

**Suggested batching for PRs:**
- PR-1: items D + C (root cleanup, no doc semantics change).
- PR-2: items A + B + E + L (file moves + redirect stubs + index pages - atomic; no README change).
- PR-3: items G–K + M + O (extract from README into new pages, README still works because old anchors still resolve to the inline content).
- PR-4: item F (README rewrite - references all extracted pages and link stubs).
- PR-5: items N + P (final sweep + CHANGELOG).

---

## 8. Open questions (need user/coordinator decision)

1. **PSGallery publish.** The biggest consumer-experience win is `Install-Module AzureAnalyzer -Repository PSGallery`. The manifest is currently missing `PrivateData.PSData` (Tags, ProjectUri, LicenseUri, ReleaseNotes), and CI has no publish step. **Is publishing to PSGallery in scope for this restructure, or is it a separate work stream?** My recommendation: separate stream, but write README §Install today with both paths so the future flip is one-line.
2. **Module GUID.** `AzureAnalyzer.psd1` GUID is the obviously-fake `0e0f0e0f-0f0e-0f0e-0f0e-0f0e0f0e0f0e`. If we ever publish to PSGallery, we **must** rotate to a real `New-Guid`. Flag it now to avoid an embarrassing first publish.
3. **Tool catalog generation.** §7 item I - should `docs/consumer/tools.md` be hand-maintained or generated from `tools/tool-manifest.json` at docs-build time? Generated keeps it true; hand-maintained is simpler. Defer to user, default to hand-maintained until we have a docs-gen script.
4. **`Invoke-AzureAnalyzer.ps1` at root vs `src/`.** Per §4 I propose **no** move. Confirm this is acceptable - alternative is a one-shot breaking change with manifest update.
5. **Stale `output*/` directories.** `output/`, `output-review/`, `output-review2/`, `output-test/` all live at repo root. Are any of these *committed* fixtures (intentional) or strays? Need to confirm before I `.gitignore` them.
6. **Squad agent Sage availability.** §7 items I/J/K can be done by Atlas alone; Sage involvement is only useful if we want a manifest-driven docs-gen step (open question 3).

---

## Lead’s summary recommendation

- **Don’t restructure repo source.** The module-manifest-at-root layout is correct.
- **Do split `docs/`** into consumer + contributor subtrees with redirect stubs.
- **Do shrink README** from 493 → ~200 lines, consumer-first, with explicit `Import-Module` documentation.
- **Do clean root** of build artefacts and the `report-template.html` asset.
- **Defer PSGallery publish** to a follow-up stream but write the install section in a publish-ready shape.

**Gate:** start work only after PRs #219, #221, #222 merge (per coordinator directive).
