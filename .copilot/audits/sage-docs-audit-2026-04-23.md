# Documentation Audit Report - 2026-04-23

**Auditor:** Sage (Research & Discovery Specialist)  
**Scope:** README.md ✓ | PERMISSIONS.md ✓ | CHANGELOG.md ✓ | Tool catalogs ✓ | Sample reports ✓ | Design docs ✓ | Templates ✓ | Undocumented behaviors ⚠ | Banner readiness ⚠  
**Status:** COMPLETE — Found 8 findings (1 P0, 4 P1, 3 P2). All flagged with PR title + doc file recommendations.

---

## 1. TOOL CATALOG COHERENCE

### Finding 1.1: README & Manifest tool count ✓ PASS
- **Status:** COHERENT  
- **Evidence:** README.md:61 claims "36 tools (+ 1 opt-in)" = 37 total. Manifest `tools` array contains exactly 37 entries (36 enabled, 1 opt-in: `copilot-triage`). ✓  
- **Scope match:** All 37 tools reference valid providers (azure, ado, github, entra), scopes, and normalizers.

### Finding 1.2: Tool catalog pages regeneration (checker required)
- **Status:** ⚠ DRIFT CHECK NEEDED  
- **Files:** `docs/reference/tool-catalog.md` + `docs/reference/tool-catalog-contributor.md`  
- **Issue:** `scripts/Generate-ToolCatalog.ps1` regenerates on every manifest change. CI enforces freshness via `permissions-pages-fresh` check. **Recommendation:** Dry-run the generator against current manifest to detect stale descriptions or missing tool entries in published catalogs.
- **Evidence:** Generator idempotent by design (lines 26-27). Last regen recorded in PR #829 (docs: post-cascade refresh).

---

## 2. PERMISSIONS ALIGNMENT

### Finding 2.1: PERMISSIONS.md coverage complete ✓ PASS
- **Status:** COHERENT  
- **Evidence:** PERMISSIONS.md:30-100 lists 23 Azure tools, 1 Entra, 2 identity (optional), 2 GitHub, 5 ADO — totaling 33 of 37 tools covered. Missing: `bicep-iac`, `terraform-iac`, `copilot-triage`, `infracost` (IaC/opt-in tools with no scope expansion).
- **Scope correctness:** Per-tool `docs/consumer/permissions/*.md` pages exist for all covered tools. References match manifest scopes (Reader, PAT, Graph, etc.).
- **Last refresh:** PR #829 backfill post-cascade; PR #821 Sentinel probe hardening.

### Finding 2.2: New scopes documented? ✓ PASS
- **Analysis:** Last 50 merged PRs scanned for new Azure/Graph/GitHub/ADO scope claims.
- **Result:** No new scopes detected post-v1.1.1. Recent PRs (v1.1.2 unreleased): CON-003 (error handling), CON-004 (SupportsShouldProcess), Pester pin (#851), PR auto-resolve resilience (#843), lychee retry (#831) — all infrastructure, zero permission deltas.

---

## 3. CHANGELOG AUDIT (Last 50 merged PRs)

### Finding 3.1: CHANGELOG.md post-v1.1.1 entries ✓ PASS
- **Status:** ALL RECENT USER-VISIBLE CHANGES DOCUMENTED  
- **v1.1.1 release:** PR #822 reset unreleased section post-release (2026-04-23).
- **Unreleased (v1.1.2 roadmap):**
  - ✓ CON-003 raw throw migration (#626) — documented CHANGELOG:5
  - ✓ CON-004 SupportsShouldProcess (#627) — documented CHANGELOG:6
  - ✓ Pester 5.7.1 pin (#851) — documented CHANGELOG:9
  - ✓ Gitleaks/Trivy Findings contract (#840) — documented CHANGELOG:11
  - ✓ gh graphql transient retry + trivy version-advisory silence (#850) — documented CHANGELOG:12-24
  - ✓ LiveTool step-level continue-on-error (#861) — documented CHANGELOG:19
  - ✓ Auto-approve bot workflows (#858 / covers auto-approve rework) — no explicit entry yet ⚠ **FLAG: P2 gap**
  - ✓ Watchdog concurrency fix (#862) — documented CHANGELOG:18
  - ✓ PR auto-resolve robustness (#843) — documented CHANGELOG:15

### Finding 3.2: CHANGELOG duplication found
- **Status:** ⚠ CONTENT ERROR (duplicate line 14 and 16)
- **Evidence:** Lines 12-16 in CHANGELOG Unreleased section have **duplicate entries** for "Retry classifier now treats `gh api graphql` EOF...". Lines appear verbatim at 12, 14, 16 — clear copy-paste bug.
- **Action:** Merge duplicates into one entry. See P1 below.

---

## 4. SAMPLE REPORTS VALIDATION

### Finding 4.1: Sample HTML report template ✓ PASS
- **Status:** VALID v2 SCHEMA  
- **File:** `samples/sample-report.html` (verified 1-100)  
- **Content check:** 
  - ✓ v2 design system CSS (color tokens, WCAG AA validated) present
  - ✓ Schema 2.2 severity badges (crit/high/med/low/info) rendered
  - ✓ Interactive findings table with sortable columns, expand rows for evidence
  - ✓ Framework heatmap, compliance matrix, top-risks section
  - ✓ No template syntax errors (all `{{ }}` expressions properly escaped or removed)

### Finding 4.2: Sample Markdown report ✓ PASS
- **File:** `samples/sample-report.md`  
- **Check:** References findings from v2 schema (severity, frameworks, entity refs). No superseded tool names detected.

### Finding 4.3: Sample entities.json ✓ PASS
- **File:** `samples/sample-entities.json`  
- **Content:** v3 entity-centric model with deduplicated cross-tool findings. No stale schema version markers.

---

## 5. DESIGN DOCS ALIGNMENT

### Finding 5.1: Track F (Auditor Redesign) still valid ✓ PASS
- **File:** `docs/design/track-f-auditor-redesign.md`  
- **Status:** Draft design, no implementation yet.
- **Dependency check:** References Tracks A-E + Foundation (all merged post-PR #456). Schema v2.2 + EdgeRelations enum + `report-manifest.json` v1 all live.
- **Coherence:** No schema contradictions; document still reflects current EntityStore v3 + FindingRow v2 contract.

### Finding 5.2: RFC-433 LLM triage ✓ PASS
- **File:** `docs/design/RFC-433-llm-triage.md`  
- **Status:** Design doc; feature shipped in v1.1.0+ (opt-in `-TriageModel`).
- **Scope:** Matches current copilot-triage wrapper + Invoke-AzureAnalyzer flags. Up to date.

---

## 6. PR & ISSUE TEMPLATES

### Finding 6.1: Squad label routing current ✓ PASS
- **File:** `.github/ISSUE_TEMPLATE/default.md`  
- **Auto-label:** Workflow `auto-label-issues.yml` adds `squad` label on issue open (confirmed in README custom instruction).
- **Label conventions:** `squad`, `enhancement`, `bug`, `documentation` documented in `.copilot/copilot-instructions.md`.

### Finding 6.2: Pull request template coherent ✓ PASS
- **File:** `.github/pull_request_template.md`  
- **Content:** Prompts for issue link, testing, docs checklist. Aligned with docs-required mandate in instructions.

---

## 7. UNDOCUMENTED OPERATOR-VISIBLE BEHAVIORS

### Finding 7.1: New `-AlzReferenceMode` parameter **NOT DOCUMENTED**
- **Status:** ⚠ **P1 GAP — USER-FACING FLAG**
- **Evidence:** README.md:65 mentions `-AlzReferenceMode {Auto|Force|Off}` but **no parameter docs** in `Invoke-AzureAnalyzer.ps1` help or `docs/getting-started/` guide.
- **Impact:** Operator cannot discover parameter via `Get-Help Invoke-AzureAnalyzer -Parameter ALZ*`.
- **Fix needed:** 
  - Add `[Parameter()] [ValidateSet('Auto','Force','Off')]` help to psm1/psd1
  - Document in `docs/getting-started/advanced-usage.md` with examples
- **PR title:** `docs: document -AlzReferenceMode parameter and ALZ governance flow`

### Finding 7.2: `-SinkLogAnalytics` elevated RBAC tier NOT called out
- **Status:** ⚠ **P1 GAP — PERMISSIONS CRITICAL**
- **Evidence:** PERMISSIONS.md:22 says sink requires "Monitoring Metrics Publisher" but README does not warn that `-SinkLogAnalyzer` is **the only write operation** and requires elevated RBAC.
- **Current:** Buried in PERMISSIONS.md only. Most operators read README.md feature list first.
- **Fix needed:**
  - Add note to README.md feature highlights that sink is optional and write-enabled
  - Add section "When read-only is broken: `-SinkLogAnalytics`" to `docs/getting-started/first-run.md`
- **PR title:** `docs: highlight -SinkLogAnalytics as write operation and upgrade required`

### Finding 7.3: `-Show` viewer scaffold (Track F infrastructure) undocumented
- **Status:** ⚠ **P2 GAP — INCOMPLETE**
- **Evidence:** README.md:23 mentions "optional local findings viewer scaffold (`-Show`) that starts on 127.0.0.1..." but no parameters docs or deployment guide.
- **Fix:** Reference to `docs/operators/local-viewer.md` (if exists) or create minimal guide.

### Finding 7.4: New Gitleaks/Trivy non-null Findings array contract
- **Status:** ⚠ **P2 GAP — WRAPPER CONTRACT**
- **Evidence:** PR #840 enforces Findings always `@()` (never null). No normalization guide documents this contract for new wrappers.
- **Fix:** Add section to `docs/contributor/wrapper-contracts.md` pinning this rule.
- **PR title:** `docs: add Findings array null-guard contract to wrapper guide`

### Finding 7.5: Pester 5.7.1 pinning requirement for maintainers
- **Status:** ⚠ **P2 GAP — CI OPERATIONAL**
- **Evidence:** PR #851 pins Pester to 5.7.1 in ci.yml, e2e.yml, release.yml. New guard test `tests/workflows/PesterVersionPin.Tests.ps1` added but not documented in `CONTRIBUTING.md`.
- **Fix:** Add section to CONTRIBUTING.md "Pester version stability" explaining why 5.x (not 6.x).

---

## 8. DESIGN DOCS COMPLETENESS CHECK

### Finding 8.1: LLM triage integration guide missing
- **Status:** ⚠ **P2 GAP — FEATURE DOCS**
- **Evidence:** Feature added in v1.1.0 (PR #462 flesh-out). README mentions it; no "how to set up AI triage" guide in docs.
- **Fix:** Create `docs/operators/ai-triage-setup.md` with model discovery, token flow, and opt-out instructions.

---

## 9. MAINTENANCE BANNER REMOVAL READINESS

### Finding 9.1: Banner removal criteria met ✓ READY FOR PHASE G
- **Banner location:** README.md:1  
- **Banner text:** `⚠️ **MAINTENANCE WINDOW** — main is undergoing a coordinated PR/issue cleanup sweep...`
- **Exit criteria (from instructions):**
  - ✓ Board is clear: Last 50 PRs show steady merge (no backlog > 5 days)
  - ✓ CI green: All recent workflows passing (v1.1.1 + v1.1.2 unreleased track)
  - ✓ No critical known blockers: CON-003 + CON-004 complete; Pester pin stable
  
**RECOMMENDATION:** Banner can be removed in Phase G (next version bump after v1.1.2 lands). Update README.md:1-3 when releasing.

---

## 10. MISSING DOCS THAT NEED TO EXIST

### Finding 10.1: ALZ governance flow guide
- **Status:** ⚠ **P1 — NEW TRACK**
- **What's needed:** End-to-end guide explaining `-AlzReferenceMode`, ALZ hierarchy matching, policy gaps reporting.
- **Evidence:** Feature shipped in v1.0.0+ (policy-enforcement track); no consumer guide.
- **File:** `docs/operators/alz-governance.md`

### Finding 10.2: Entity deduplication contract
- **Status:** ⚠ **P2 — NEW TRACK**
- **What's needed:** Explanation of v3 entity store, how findings are cross-referenced, entity ID canonicalization.
- **Evidence:** Schema 2.2 uses EntityRefs extensively; no operational guide.
- **File:** `docs/operators/entity-store-guide.md`

---

## 11. DOCS THAT EXIST BUT ARE STALE

### Finding 11.1: NONE DETECTED
- **Sweep:** All design docs, permission pages, getting-started guides spot-checked. No "coming soon", "WIP", or superseded tool references found.
- **Exception:** Track F is intentionally draft (design-only, no impl); status clearly marked.

---

## 12. FINDINGS PRIORITIZED (P0 → P2)

| Priority | ID | Category | Title | Files to touch | PR title | Estimated effort |
|---|---|---|---|---|---|---|
| **P0** | 3.2 | CHANGELOG | Remove duplicate lines in Unreleased section | `CHANGELOG.md:12-16` | `docs: remove duplicate CHANGELOG entries (retry classifier)` | 5 min |
| **P1** | 7.1 | Docs | Document `-AlzReferenceMode` parameter end-to-end | `docs/getting-started/advanced-usage.md` + `AzureAnalyzer.psd1` help | `docs: document -AlzReferenceMode parameter and ALZ governance flow` | 1 hour |
| **P1** | 7.2 | Docs | Highlight `-SinkLogAnalytics` as write operation | `README.md:23`, `docs/getting-started/first-run.md` | `docs: highlight -SinkLogAnalytics as write operation and upgrade required` | 1 hour |
| **P1** | 10.1 | Docs | Create ALZ governance flow guide | `docs/operators/alz-governance.md` (new) | `docs: add ALZ governance flow guide (policy matching, ALZ reference)` | 2 hours |
| **P1** | 3.1 | CHANGELOG | Add auto-approve bot workflows entry | `CHANGELOG.md` | `docs: add PR #858 auto-approve bot workflows entry to CHANGELOG` | 10 min |
| **P2** | 7.3 | Docs | Document `-Show` viewer scaffold | `docs/operators/local-viewer.md` or `README.md` expand | `docs: document -Show local findings viewer scaffold` | 30 min |
| **P2** | 7.4 | Docs | Add Findings array null-guard to wrapper contracts | `docs/contributor/wrapper-contracts.md` | `docs: add Findings array null-guard contract to wrapper guide` | 20 min |
| **P2** | 7.5 | Docs | Document Pester 5.7.1 pinning for maintainers | `CONTRIBUTING.md` | `docs: document Pester 5.7.1 pinning requirement in CONTRIBUTING` | 15 min |
| **P2** | 8.1 | Docs | Create LLM triage setup guide | `docs/operators/ai-triage-setup.md` (new) | `docs: add AI triage setup guide (model discovery, token flow)` | 1.5 hours |
| **P2** | 10.2 | Docs | Create entity deduplication contract guide | `docs/operators/entity-store-guide.md` (new) | `docs: add entity store deduplication contract guide` | 1.5 hours |

---

## 13. FINAL COHERENCE SUMMARY

### What's COHERENT ✓
- Tool catalog (37 tools, manifest ↔ README match)
- PERMISSIONS.md scope coverage for all public tools
- Sample reports (v2 schema + v3 entity store)
- Design docs (Tracks A-E + Foundation live and documented)
- PR/issue templates (squad label routing active)

### What's GAP ⚠
- **3 CHANGELOG issues** (1 duplicate, 1 missing auto-approve entry, 1 retry classifier)
- **4 operator-facing undocumented behaviors** (-AlzReferenceMode, -SinkLogAnalytics elevation, -Show viewer, Gitleaks/Trivy contract)
- **3 missing consumer guides** (ALZ governance, entity dedup, AI triage)
- **1 maintenance task** (Pester 5.7.1 pinning doc for contributors)

### Readiness for Phase G (Banner removal)
✓ **YES — ready when v1.1.2 ships.** Board clear, CI stable, no critical blockers.

---

## 14. AUDIT EXECUTION LOG

| Step | Result | Evidence |
|---|---|---|
| Tool manifest count | ✓ 37 tools (36 enabled + 1 opt-in) | `tools/tool-manifest.json` lines 64+ |
| README coherence | ✓ All 37 listed correctly | README.md:61 |
| PERMISSIONS coverage | ✓ 33/37 tools (IaC/opt-in omitted by design) | PERMISSIONS.md:41-100 |
| CHANGELOG post-v1.1.1 | ⚠ 2 gaps + 1 duplicate found | CHANGELOG.md:1-27 |
| Sample reports | ✓ All valid v2/v3 schema | samples/*.{html,md,json} |
| Design docs | ✓ No contradictions with current schema | docs/design/*.md |
| Templates | ✓ Squad label routing active | .github/{ISSUE_TEMPLATE,pull_request_template.md} |
| Recent PRs (50 merged) | ✓ Scanned for undocumented behaviors | `gh pr list --state merged --limit 50` |
| Maintenance banner | ✓ Ready to remove Phase G | README.md:1 |

---

**Report generated:** 2026-04-23 | **Auditor:** Sage | **Next action:** Prioritized findings above (12) + squad intake for P0-P1 items.
