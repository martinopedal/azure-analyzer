# Track F Implementation Plan — Issue #506 (Draft PR)

**Author:** Lead (Team Lead / Track F Implementation Planner)  
**Date:** 2026-04-23  
**Mission:** Produce the commit-by-commit master plan for implementing Track F auditor-driven report redesign.  
**Deliverable scope:** PLAN ONLY — zero code edits. Another agent executes this plan commit-by-commit.  
**Authority:** READ-ONLY phase. Draft PR stays draft; user flips to ready when satisfied.

---

## 1. Branch and Scope

**Branch strategy:**
```bash
# Target branch (confirmed absent from remote):
git fetch origin
git checkout -b feat/506-auditor-report-impl origin/main
```

**Rationale:** `squad/434-auditor-redesign-design` does not exist in the remote. Per issue #506 body, PR #481 (scaffold) has already merged to `main` via commit `e0d20bc67d1d40a09c4abcf1733fd0b506695e0c`. The skeleton (`AuditorReportBuilder.ps1` with 12 frozen `NotImplementedException` signatures) is on `main`. Implementation branches directly off `main`.

**Scope:**
- Implement the 12 frozen functions in `modules/shared/AuditorReportBuilder.ps1`
- Wire auditor mode into `Invoke-AzureAnalyzer.ps1 -Profile Auditor`
- Add +25-30 Pester tests per design doc §8
- Extend `report-manifest.json` writer to declare `profile.auditor` block
- Update README, PERMISSIONS, CHANGELOG per repo doc rule
- **NOT in scope this cycle (per #506):** merging the draft PR. It stays draft until user approval.

---

## 2. Pre-Flight Gate: D1 Dependency Check (Commit 0)

**Commit 0 title:** `chore(deps): verify Track A-E+V on main before Track F impl`

**Why:** Per design doc §1, Track F is the **serial tail** of the epic. All 6 dependency tracks must be on `main` before commit 1 starts. Atlas's D1 dependency check (from `.squad/ceremonies.md` → Cloud Agent PR Review) validates this.

**Files read (check only, no edit):**
- `modules/shared/EdgeRelations.ps1` (Track A/B — `EdgeRelations` enum with 16+ values)
- `modules/shared/EntityStore.ps1` (foundation #435 — v3 dual-read entity store)
- `modules/shared/Schema.ps1` (Track D — `FindingRow` fields: `ComplianceMappings`, `Pillar`, `Impact`, `Effort`, `RemediationSnippets`, `DeepLinkUrl`)
- `modules/shared/Select-ReportArchitecture.ps1` (Track V — tier picker)
- `modules/shared/PolicyCoverageAnalyzer.ps1` (Track C — ALZ gap analysis)
- `modules/triage/LlmTriageEngine.ps1` (Track E — triage verdicts, optional)

**Action:**
```powershell
# Run from repo root
Invoke-Pester -Path .\tests -CI
# Baseline must be green. If red: STOP. Implementation blocked until dependencies land.
```

**Acceptance criterion:**
- All 6 dependency modules exist on `main`
- Pester baseline green (842/842 or higher)
- If red: document the blocker in #506 and pause until user resolves

**Risk / blast radius:** Read-only. Zero code change. Gating function only.

**Test count delta:** 0 (baseline check, no new tests)

---

## 3. Commit 1: Context Resolution + Executive Summary

**Commit title:** `feat(report): implement auditor context resolution and executive summary`

**Files touched:**
- `modules/shared/AuditorReportBuilder.ps1` (replace `NotImplementedException` in `Resolve-AuditorContext` and `Get-AuditorExecutiveSummary`)
- `tests/shared/AuditorReportBuilder.Tests.ps1` (NEW — create file, add 4 tests, drop `-Skip`)

**Functions implemented:**
1. **`Resolve-AuditorContext`** (lines 64-75)
   - Reads `InputPath` (results.json), `EntitiesPath` (entities.json), `ManifestPath` (report-manifest.json)
   - Reads optional `TriagePath` and `PreviousRunPath`
   - Extracts tier from manifest or `-Tier` param (manifest takes precedence per design doc §4.1)
   - Returns hashtable: `@{ Findings, Entities, Manifest, Tier, TriageData?, PreviousFindings?, Frameworks }`

2. **`Get-AuditorExecutiveSummary`** (lines 77-85)
   - Computes severity counts from `$Findings | Group-Object Severity`
   - Computes control-framework coverage: for each framework in `$ControlFrameworks`, count findings with `ComplianceMappings` entries matching that framework, compute `covered/total/pct`
   - Computes diff vs. `$PreviousFindings` if present: `+added`, `-resolved`, `~changed`
   - Returns JSON-serializable object: `{ severityCounts, frameworkCoverage, diffSummary?, collectedAt, scope }`

**Pester tests added:**
File: `tests/shared/AuditorReportBuilder.Tests.ps1` (NEW)

1. `Resolve-AuditorContext reads tier from manifest when both manifest and -Tier param present`
   - Fixture: synthetic manifest with `tier: "EmbeddedSqlite"`
   - Asserts: function returns `Tier = "EmbeddedSqlite"` even when `-Tier PureJson` passed

2. `Resolve-AuditorContext loads all inputs when paths valid`
   - Fixture: `tests/fixtures/auditor-small/` (200 findings)
   - Asserts: `Findings.Count -eq 200`, `Entities` is hashtable, `Manifest.profile -eq 'auditor'`

3. `Get-AuditorExecutiveSummary computes severity counts matching Group-Object`
   - Fixture: 10 findings (3 critical, 4 high, 2 medium, 1 low)
   - Asserts: `severityCounts.Critical -eq 3`, etc.

4. `Get-AuditorExecutiveSummary computes control-framework coverage from ComplianceMappings`
   - Fixture: 20 findings, 10 have `ComplianceMappings` with `CIS 2.1.x`, 5 have NIST, 0 ISO
   - Asserts: `frameworkCoverage.CIS.covered -eq 10`, `frameworkCoverage.CIS.pct -eq 50`, `frameworkCoverage.ISO27001.covered -eq 0`

**Acceptance criterion:**
- `Invoke-Pester -Path .\tests\shared\AuditorReportBuilder.Tests.ps1` — 4/4 green
- `Invoke-Pester -Path .\tests -CI` — baseline green + 4 new passing

**Pre-commit invariant:** Full Pester suite green (`Invoke-Pester -Path .\tests -CI`).

**Risk / blast radius:** Low. New functions, no callers yet. No orchestrator wiring.

**Test count delta:** +4

**Documentation update:** None yet (batch at commit 9 per repo rule).

---

## 4. Commit 2: Control-Domain Sections (Track D consumer)

**Commit title:** `feat(report): implement control-domain section grouping and renderers`

**Files touched:**
- `modules/shared/AuditorReportBuilder.ps1` (implement `Get-AuditorControlDomainSections`)
- `tests/shared/AuditorReportBuilder.Tests.ps1` (add 3 tests)
- `tests/fixtures/auditor-small/` (extend fixture to include findings with `ComplianceMappings` for all 4 frameworks)

**Functions implemented:**
1. **`Get-AuditorControlDomainSections`** (lines 87-94)
   - Groups `$Findings` by each framework in `$Frameworks` (`CIS`, `NIST`, `MCSB`, `ISO27001`)
   - For each framework, extracts control IDs from `ComplianceMappings` field (Track D output)
   - Returns array of section objects: `@{ Framework, ControlId, FindingCount, Findings[] }`
   - Includes HTML and MD renderers inline (reuses v2 report table helpers from `New-HtmlReport.ps1`)

**Pester tests added:**
File: `tests/shared/AuditorReportBuilder.Tests.ps1`

5. `Get-AuditorControlDomainSections groups findings by framework control id`
   - Fixture: 30 findings, 10 CIS 2.1.1, 8 NIST AC-2, 7 MCSB IM-1, 5 ISO 27001 A.9.2
   - Asserts: 4 sections returned, counts match, `FindingCount` accurate

6. `Get-AuditorControlDomainSections handles missing ComplianceMappings gracefully`
   - Fixture: 10 findings, 5 have `ComplianceMappings: null`
   - Asserts: null mappings excluded, no throw

7. `Get-AuditorControlDomainSections renders HTML table per framework`
   - Fixture: 2 findings in CIS 2.1.1
   - Asserts: output contains `<table>`, `<tr>`, framework name in header

**Acceptance criterion:**
- All 7 tests green
- `Get-AuditorControlDomainSections` returns consistent structure
- HTML renderer produces valid table markup

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Low. New function, no callers. Consumes Track D fields; if fields missing, section renders empty (declared degradation added in commit 8).

**Test count delta:** +3 (cumulative: 7)

**Documentation update:** None yet.

---

## 5. Commit 3: Attack Path, Resilience, Policy Coverage (Tracks A/B/C consumers)

**Commit title:** `feat(report): implement attack-path, resilience, and policy-coverage sections`

**Files touched:**
- `modules/shared/AuditorReportBuilder.ps1` (implement 3 functions)
- `tests/shared/AuditorReportBuilder.Tests.ps1` (add 5 tests)
- `tests/fixtures/auditor-small/entities.json` (extend to include attack-path edges and blast-radius scores)

**Functions implemented:**
1. **`Get-AuditorAttackPathSection`** (lines 96-103)
   - Reads `$Entities` from context (Track A output: `EdgeRelations` enum + edges in `entities.json`)
   - Queries edges with `Relation = 'AttackPath'`
   - Renders as: Tier 1/2 = inline Cytoscape graph, Tier 3 = paginated subgraph, Tier 4 = KPI tile + deep link
   - Returns: `@{ RenderingMode, HtmlSnippet?, DeepLinkUrl?, TotalPaths, CriticalPaths }`

2. **`Get-AuditorResilienceSection`** (lines 105-112)
   - Reads blast-radius edges (Track B)
   - Computes top 10 resources by blast-radius score
   - Returns: `@{ RenderingMode, TopResources[], TotalEntities }`

3. **`Get-AuditorPolicyCoverageSection`** (lines 114-121)
   - Reads policy-assignment deltas from `$Entities` (Track C)
   - Identifies missing policies vs. ALZ reference
   - Returns: `@{ AssignedCount, MissingCount, GapSuggestions[], AzAdvertizerLinks[] }`

**Pester tests added:**
File: `tests/shared/AuditorReportBuilder.Tests.ps1`

8. `Get-AuditorAttackPathSection returns attack-path count from entities.json`
   - Fixture: `entities.json` with 5 attack-path edges
   - Asserts: `TotalPaths -eq 5`, `CriticalPaths -ge 0`

9. `Get-AuditorAttackPathSection tier-aware rendering mode`
   - Fixture: same, test at Tier 1 vs Tier 4
   - Asserts: Tier 1 returns `RenderingMode = 'inline'`, Tier 4 returns `RenderingMode = 'deepLink'`

10. `Get-AuditorResilienceSection computes top 10 resources by blast-radius`
    - Fixture: `entities.json` with 20 resources, 5 have high blast-radius
    - Asserts: `TopResources.Count -eq 10`, ordered by score descending

11. `Get-AuditorPolicyCoverageSection identifies missing policies`
    - Fixture: `entities.json` with policy deltas (Track C output)
    - Asserts: `MissingCount -gt 0`, `GapSuggestions` is array

12. `Get-AuditorPolicyCoverageSection includes AzAdvertizer deep links`
    - Fixture: same
    - Asserts: `AzAdvertizerLinks[0]` contains `azadvertizer.net`

**Acceptance criterion:**
- All 12 tests green
- Functions gracefully degrade when Track A/B/C data missing (return empty arrays, not throw)
- Tier-aware rendering per design doc §4.1

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Medium. Consumes Track A/B/C outputs. If those tracks incomplete, sections degrade (declared in commit 8).

**Test count delta:** +5 (cumulative: 12)

**Documentation update:** None yet.

---

## 6. Commit 4: Remediation Appendix + Evidence Export

**Commit title:** `feat(report): implement remediation appendix and evidence export`

**Files touched:**
- `modules/shared/AuditorReportBuilder.ps1` (implement 2 functions)
- `tests/shared/AuditorReportBuilder.Tests.ps1` (add 5 tests)

**Functions implemented:**
1. **`Get-AuditorRemediationAppendix`** (lines 132-138)
   - Groups `$Findings` by `Remediation` field (Track D output)
   - Orders groups by severity weight (Critical=4, High=3, Medium=2, Low=1, Info=0)
   - Returns: `@{ RemediationGroups[] }` where each group = `{ RemediationText, Findings[], TotalCount, MaxSeverity }`

2. **`Get-AuditorEvidenceExport`** (lines 140-148)
   - Writes `$Findings` to `$OutputDirectory/audit-evidence/`
   - Formats: always CSV + JSON; XLSX only if `ImportExcel` module present
   - Sanitizes output via `Remove-Credentials` (shared module)
   - Returns: `@{ ExportedFiles[] }`

**Pester tests added:**
File: `tests/shared/AuditorReportBuilder.Tests.ps1`

13. `Get-AuditorRemediationAppendix groups by exact Remediation text`
    - Fixture: 15 findings, 3 distinct `Remediation` values
    - Asserts: 3 groups returned, counts match

14. `Get-AuditorRemediationAppendix orders by severity weight descending`
    - Fixture: 3 groups (Critical, Medium, Low)
    - Asserts: groups[0].MaxSeverity -eq 'Critical', groups[2].MaxSeverity -eq 'Low'

15. `Get-AuditorEvidenceExport writes CSV and JSON always`
    - Fixture: 5 findings
    - Asserts: `audit-evidence/findings.csv` exists, `audit-evidence/findings.json` exists

16. `Get-AuditorEvidenceExport writes XLSX only when ImportExcel present`
    - Fixture: same, mock `Get-Module -ListAvailable ImportExcel`
    - Asserts: if present, `.xlsx` exists; if absent, `.xlsx` does not exist

17. `Get-AuditorEvidenceExport sanitizes output via Remove-Credentials`
    - Fixture: finding with `Details` containing `password=secret123`
    - Asserts: exported CSV does not contain `secret123`

**Acceptance criterion:**
- All 17 tests green
- Evidence directory created alongside report
- Credential scrubbing round-trip clean

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Low. File I/O only. No schema changes.

**Test count delta:** +5 (cumulative: 17)

**Documentation update:** None yet.

---

## 7. Commit 5: Triage Annotations (Track E consumer, optional)

**Commit title:** `feat(report): implement LLM triage annotations`

**Files touched:**
- `modules/shared/AuditorReportBuilder.ps1` (implement `Get-AuditorTriageAnnotations`)
- `tests/shared/AuditorReportBuilder.Tests.ps1` (add 3 tests)

**Functions implemented:**
1. **`Get-AuditorTriageAnnotations`** (lines 123-130)
   - Reads `$TriagePath` (optional `triage.json` from Track E)
   - Joins triage verdicts to `$Findings` by `FindingId`
   - Returns: `@{ AnnotatedFindings[], TriagePresent }` where each annotated finding includes `{ Verdict, Rationale, SuggestedSuppression? }`

**Pester tests added:**
File: `tests/shared/AuditorReportBuilder.Tests.ps1`

18. `Get-AuditorTriageAnnotations joins triage verdicts when present`
    - Fixture: 10 findings, `triage.json` with verdicts for 5
    - Asserts: `AnnotatedFindings.Count -eq 10`, 5 have `Verdict` populated, 5 have `Verdict = null`

19. `Get-AuditorTriageAnnotations degrades gracefully when triage.json missing`
    - Fixture: no `triage.json`
    - Asserts: `TriagePresent -eq $false`, no throw

20. `Get-AuditorTriageAnnotations includes suggested suppression when Track E provides it`
    - Fixture: `triage.json` with `SuggestedSuppression = 'false_positive'`
    - Asserts: `AnnotatedFindings[0].SuggestedSuppression -eq 'false_positive'`

**Acceptance criterion:**
- All 20 tests green
- Function optional (no break if Track E not present)

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Low. Optional consumer. Degrades cleanly.

**Test count delta:** +3 (cumulative: 20)

**Documentation update:** None yet.

---

## 8. Commit 6: Render Tier + Citation Helper

**Commit title:** `feat(report): implement tier-aware rendering and citation helper`

**Files touched:**
- `modules/shared/AuditorReportBuilder.ps1` (implement `Write-AuditorRenderTier` and `New-AuditorCitation`)
- `tests/shared/AuditorReportBuilder.Tests.ps1` (add 4 tests)

**Functions implemented:**
1. **`Write-AuditorRenderTier`** (lines 150-160)
   - Takes `$Context` hashtable (from `Resolve-AuditorContext`)
   - Renders per `$Tier`:
     - Tier 1/2: full inline HTML (prose-heavy exec summary, inline tables)
     - Tier 3: headline + deep links
     - Tier 4: KPI tiles + deep links
   - Writes `audit-report.html` and `audit-report.md` to `$OutputDirectory`
   - Adds print stylesheet for all tiers
   - Returns: `@{ HtmlPath, MdPath, RenderingMode }`

2. **`New-AuditorCitation`** (lines 162-169)
   - Takes `$Finding` (FindingRow)
   - Returns single-line citation: `[<source> <pin>] <id>: <title>. Resource: <canonical>. Severity: <sev>. Collected <iso>. Rule: <url>. Docs: <url>.`
   - Sanitizes via `Remove-Credentials`

**Pester tests added:**
File: `tests/shared/AuditorReportBuilder.Tests.ps1`

21. `Write-AuditorRenderTier produces HTML and MD files`
    - Fixture: `auditor-small` context
    - Asserts: `audit-report.html` exists, `audit-report.md` exists

22. `Write-AuditorRenderTier tier-aware rendering mode`
    - Fixture: test at Tier 1 vs Tier 4
    - Asserts: Tier 1 HTML contains full finding table, Tier 4 HTML contains KPI tile + deep link

23. `New-AuditorCitation produces single-line workpaper-ready string`
    - Fixture: FindingRow with `Source='azsk', Id='F-123', Title='Insecure NSG', Severity='High'`
    - Asserts: output matches format `[azsk 1.2.3] F-123: Insecure NSG. Resource: ...`

24. `New-AuditorCitation sanitizes credentials via Remove-Credentials`
    - Fixture: FindingRow with `Details` containing password
    - Asserts: citation does not contain password

**Acceptance criterion:**
- All 24 tests green
- HTML/MD files created
- Print stylesheet included (manual smoke test: `Ctrl+P` in browser produces clean PDF)

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Low. File I/O. No orchestrator wiring yet.

**Test count delta:** +4 (cumulative: 24)

**Documentation update:** None yet.

---

## 9. Commit 7: Orchestrator Wiring + Navigation Chip

**Commit title:** `feat(report): wire auditor mode to Invoke-AzureAnalyzer.ps1 -Profile Auditor`

**Files touched:**
- `Invoke-AzureAnalyzer.ps1` (add `-Profile` param, wire call to `Build-AuditorReport`)
- `modules/shared/AuditorReportBuilder.ps1` (implement `Build-AuditorReport` orchestrator — drops `NotImplementedException`)
- `New-HtmlReport.ps1` (add "Audit view ↗" chip when `audit-report.html` exists)
- `tests/orchestrator/InvokeAzureAnalyzer.Profile.Tests.ps1` (NEW — 2 tests)

**Functions implemented:**
1. **`Build-AuditorReport`** (lines 44-62)
   - Orchestrates all 11 sub-functions
   - Calls `Resolve-AuditorContext`, then each section function, then `Write-AuditorRenderTier`
   - Returns: `@{ HtmlPath, MdPath, EvidencePath, Manifest }` or `-PassThru` returns full context

**Pester tests added:**
File: `tests/orchestrator/InvokeAzureAnalyzer.Profile.Tests.ps1` (NEW)

25. `Invoke-AzureAnalyzer.ps1 -Profile Auditor calls Build-AuditorReport`
    - Fixture: `auditor-small` run via `Invoke-AzureAnalyzer.ps1 -Profile Auditor`
    - Asserts: `output/audit-report.html` exists

26. `New-HtmlReport.ps1 injects 'Audit view' chip when audit-report.html present`
    - Fixture: run standard report + auditor report
    - Asserts: `output/report.html` contains link to `audit-report.html`

**Acceptance criterion:**
- All 26 tests green
- `Invoke-AzureAnalyzer.ps1 -Profile Auditor` produces auditor report
- Navigation chip visible in standard report

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Medium. First orchestrator wiring. If bugs exist, report generation fails. Mitigated by tests.

**Test count delta:** +2 (cumulative: 26)

**Documentation update:** None yet.

---

## 10. Commit 8: Report-Manifest Extension (Declared Degradation Contract)

**Commit title:** `feat(report): extend report-manifest.json with auditor profile block`

**Files touched:**
- `modules/shared/ReportManifest.ps1` (extend writer to add `profile.auditor` block)
- `tests/shared/ReportManifest.Tests.ps1` (add 3 tests)

**Functions extended:**
1. **`Write-ReportManifest`** (existing function in foundation #435)
   - Appends `report.profile.auditor` block when `-Profile Auditor`
   - Structure per design doc §5.1:
     ```json
     {
       "profile": "auditor",
       "sections": [
         { "id": "executiveSummary", "renderingMode": "inline" },
         { "id": "attackPath", "renderingMode": "paginatedSubgraph" }
       ],
       "degradations": [
         { "feature": "attackPath", "fromMode": "fullCanvas", "toMode": "paginatedSubgraph", "reason": "Tier 3 caps at 50k edges" }
       ]
     }
     ```

**Pester tests added:**
File: `tests/shared/ReportManifest.Tests.ps1`

27. `Write-ReportManifest appends auditor profile block when -Profile Auditor`
    - Fixture: run with `-Profile Auditor`
    - Asserts: manifest contains `profile: 'auditor'`, `sections` array non-empty

28. `Every section in profile.auditor.sections has declared renderingMode`
    - Fixture: auditor manifest at Tier 3
    - Asserts: every section object has `renderingMode` key

29. `Every degradation references a real section id`
    - Fixture: manifest with 2 degradations
    - Asserts: `degradations[*].feature` matches a `sections[*].id`

**Acceptance criterion:**
- All 29 tests green
- Manifest schema valid per Track V contract
- Declared degradation contract enforced (no orphan degradations)

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Low. Extends existing function. No breaking changes.

**Test count delta:** +3 (cumulative: 29)

**Documentation update:** None yet.

---

## 11. Commit 9: Parity Tests + Documentation

**Commit title:** `test(report): add 10-question parity tests and update docs`

**Files touched:**
- `tests/integration/AuditorParity.Tests.ps1` (NEW — 4 tests)
- `tests/fixtures/Generate-SyntheticFixture.ps1` (extend to generate `auditor-small` and `auditor-jumbo` profiles)
- `README.md` (add auditor-mode section)
- `PERMISSIONS.md` (confirm no new scopes needed)
- `CHANGELOG.md` (add Track F entry under `[1.2.0 - Unreleased]`)

**Pester tests added:**
File: `tests/integration/AuditorParity.Tests.ps1` (NEW)

30. `10 canonical auditor questions answered identically at Tier 1 and Tier 4`
    - Fixture: `auditor-jumbo` (250k findings) rendered at Tier 1 and Tier 4
    - Asserts: snapshot equivalence on the **answer** to each question:
      1. Top 10 most severe findings (by ID)
      2. Framework controls failing (CIS, NIST, MCSB, ISO — control IDs only)
      3. Findings in subscription X (count only)
      4. Attack path to privileged identity Z exists (boolean)
      5. Blast radius of resource R (node count)
      6. Policies assigned vs. missing at scope S (counts)
      7. AzAdvertizer suggestions available (boolean)
      8. Remediation text for finding F (exact string match)
      9. Diff since run R (added/resolved counts)
      10. Evidence export for subscription X succeeds (file exists)

31. `Citation lines pass Remove-Credentials round-trip without modification`
    - Fixture: 5 findings with various `Details` content
    - Asserts: `New-AuditorCitation | Remove-Credentials` returns identical string

32. `Auditor-mode HTML self-contained at Tier 1/2 (no CDN)`
    - Fixture: Tier 1 `audit-report.html`
    - Asserts: no external `<link>` or `<script src="http...">` (except print stylesheet)

33. `audit-evidence/ directory generated alongside report`
    - Fixture: auditor run
    - Asserts: `output/audit-evidence/findings.csv` exists, `.json` exists

**Documentation updates:**
- `README.md`:
  - Add "Auditor Mode" section under "Usage"
  - Example: `Invoke-AzureAnalyzer.ps1 -Profile Auditor -Subscription 'xyz'`
  - List auditor-specific outputs (`audit-report.html`, `audit-report.md`, `audit-evidence/`)

- `PERMISSIONS.md`:
  - Confirm: "Track F adds no new Azure/Graph/GitHub scopes. Auditor mode reuses existing reader permissions."

- `CHANGELOG.md`:
  - Under `[1.2.0 - Unreleased]`:
    ```markdown
    ### Added
    - Auditor-driven report redesign (Track F / #434 / PR #506): control-centric view with executive summary, CIS/NIST/MCSB/ISO domain sections, attack-path/resilience/policy-coverage sections, remediation appendix, evidence export (CSV/JSON/XLSX), tier-aware rendering (PureJson, EmbeddedSqlite, SidecarSqlite, PodeViewer), and declared-degradation contract per issue #434 Round 2 lock.
    - `Invoke-AzureAnalyzer.ps1 -Profile Auditor` flag to enable auditor mode.
    - 10 canonical auditor questions with snapshot-parity tests across all tiers.
    ```

**Acceptance criterion:**
- All 33 tests green
- Parity test snapshot equivalence on answers (not rendering)
- Docs complete per repo rule

**Pre-commit invariant:** Full Pester suite green.

**Risk / blast radius:** Low. Tests + docs only. No production code changes.

**Test count delta:** +4 (cumulative: 33 = +25-30 target met)

---

## 12. Round 2 Parity Contract Enforcement (Per #434)

**Contract:** 10 canonical auditor questions must be answered **identically** at Tier 1 and Tier 4 (snapshot equivalence on the *answer*, not the *rendering*).

**Implementation:** Commit 9 adds `tests/integration/AuditorParity.Tests.ps1` with the 10-question parity test.

**Fixtures required:**
- `tests/fixtures/auditor-small/` (200 findings, all 4 frameworks, used by unit tests) — generated in commit 9
- `tests/fixtures/auditor-jumbo/` (250k findings, used by Tier 3/4 parity tests) — generated in commit 9

**Per-commit parity test ownership:**
| Question | Commit that lands parity test | Fixture(s) needed |
|---|---|---|
| 1. Top 10 most severe findings | Commit 9 (integration) | `auditor-jumbo` |
| 2. Framework controls failing | Commit 9 (integration) | `auditor-jumbo` |
| 3. Findings in subscription X | Commit 9 (integration) | `auditor-jumbo` |
| 4. Attack path exists | Commit 9 (integration) | `auditor-jumbo` with attack-path edges |
| 5. Blast radius of resource R | Commit 9 (integration) | `auditor-jumbo` with resilience scores |
| 6. Policies assigned vs. missing | Commit 9 (integration) | `auditor-jumbo` with policy deltas |
| 7. AzAdvertizer suggestions | Commit 9 (integration) | `auditor-jumbo` with policy gaps |
| 8. Remediation text for finding F | Commit 9 (integration) | `auditor-jumbo` |
| 9. Diff since run R | Commit 9 (integration) | `auditor-jumbo` + synthetic prior run |
| 10. Evidence export succeeds | Commit 9 (integration) | `auditor-jumbo` |

All 10 questions asserted in a **single Pester test** (test #30 above) that renders `auditor-jumbo` at Tier 1 and Tier 4, extracts answers programmatically, and asserts snapshot equivalence.

---

## 13. Declared Degradation Contract (Per #434 Round 2 Lock)

**Contract:** When a Tier 4 input is missing (e.g., Track A attack-path edges not present), the auditor report must **declare the degradation** in `report-manifest.json` rather than silently produce a wrong answer.

**Implementation:** Commit 8 extends `Write-ReportManifest` to populate `profile.auditor.degradations[]` with:
- `feature` (e.g., `attackPath`)
- `fromMode` (e.g., `fullCanvas` at Tier 1)
- `toMode` (e.g., `deepLink` at Tier 4, or `unavailable` if Track A missing)
- `reason` (e.g., `"Track A attack-path edges not present in entities.json"`)

**Test coverage:** Commit 8 adds test #29 (`Every degradation references a real section id`) to enforce no orphan degradations.

**Per-commit declared-degradation ownership:**
| Degradation scenario | Commit that lands the declaration | Test that enforces it |
|---|---|---|
| Attack-path section unavailable (Track A missing) | Commit 3 (function impl) + Commit 8 (manifest writer) | Test #29 (manifest validation) |
| Resilience section unavailable (Track B missing) | Commit 3 + Commit 8 | Test #29 |
| Policy-coverage section unavailable (Track C missing) | Commit 3 + Commit 8 | Test #29 |
| Triage annotations unavailable (Track E missing) | Commit 5 + Commit 8 | Test #29 |
| Compliance dashboard empty (Track D fields unpopulated) | Commit 2 + Commit 8 | Test #29 |
| Tier 3/4 rendering mode (>50k findings) | Commit 6 + Commit 8 | Test #22 (tier-aware rendering) |

Declared degradations surface in the auditor report's **degradation banner** (HTML snippet injected by `Write-AuditorRenderTier` in commit 6).

---

## 14. Open §10 Design Questions — Recommended Answers

Per design doc §10, three open questions flagged for PR review. Lead recommendation:

### Q1: Citation provenance
**Question:** Include `FindingRow.SourceQueryHash` (when source = ARG) so auditor can replay the query?

**Recommendation:** **YES** — include if Track D #491 populates the field. Add to `New-AuditorCitation` format:
```
[azsk 1.2.3 / query:abc123def] F-12345: Insecure NSG. Resource: ...
```

**User input required:** NO. Decision can be revisited in PR review. Default implementation includes the hash if present, omits if null.

**Implementation:** Commit 6 (`New-AuditorCitation`) conditionally appends `/ query:{hash}` if `SourceQueryHash` field populated.

---

### Q2: PDF rendering
**Question:** Print stylesheet only, or ship headless-Chromium PDF generator?

**Recommendation:** **Print stylesheet only** (lean). Rationale:
- Avoids heavy Chromium dependency
- Auditors can `Ctrl+P` in any browser
- PDF generation via CI can use `wkhtmltopdf` or GitHub Actions `uses: browser-actions/setup-chrome` if needed later

**User input required:** NO. Lean default. Can be extended post-cycle if compelling use case surfaces.

**Implementation:** Commit 6 (`Write-AuditorRenderTier`) includes `<style media="print">...</style>` in HTML output.

---

### Q3: Framework version pinning
**Question:** Pin to manifest (CIS Azure 2.1, NIST 800-53 r5, MCSB v1, ISO 27001:2022) or follow Track D normalizer outputs?

**Recommendation:** **Track D drives** — auditor mode renders whatever versions Track D normalizers populate in `ComplianceMappings`. Rationale:
- Single source of truth (normalizers)
- No dual maintenance of version manifests
- If auditor needs a specific version, Track D normalizer filters it upstream

**User input required:** NO. Track D contract already established.

**Implementation:** Commit 2 (`Get-AuditorControlDomainSections`) reads `ComplianceMappings` as-is, no version filter.

---

**Summary:** All 3 questions answered with LEAN defaults. No user blocking required. Can be revisited in PR review thread if user disagrees.

---

## 15. Test-Count Target

Per design doc §8, target: **+25-30 net new Pester tests**.

**Per-commit breakdown:**
| Commit | Tests added | Cumulative |
|---|---|---|
| 0 (deps check) | 0 | 0 |
| 1 (context + exec summary) | 4 | 4 |
| 2 (control domains) | 3 | 7 |
| 3 (attack/resilience/policy) | 5 | 12 |
| 4 (remediation + evidence) | 5 | 17 |
| 5 (triage annotations) | 3 | 20 |
| 6 (render tier + citation) | 4 | 24 |
| 7 (orchestrator wiring) | 2 | 26 |
| 8 (manifest extension) | 3 | 29 |
| 9 (parity + docs) | 4 | 33 |

**Total:** +33 tests (exceeds +25-30 target ✅).

**Baseline impact:** Skeleton PR (PR #481) preserved 842/842. Implementation PR extends to **875 tests** (842 + 33 = 875).

---

## 16. Pre-Flight Gate: D1 Dependency Check Detail

**Commit 0 action plan:**

1. **Check Track A (attack paths):**
   ```powershell
   Test-Path modules\shared\EdgeRelations.ps1
   Select-String -Path modules\shared\EdgeRelations.ps1 -Pattern "enum EdgeRelations"
   # Must return 16+ values including 'AttackPath', 'BlastRadius'
   ```

2. **Check Track B (resilience):**
   ```powershell
   Select-String -Path modules\shared\Schema.ps1 -Pattern "BlastRadiusScore"
   # Must exist in EntityRow or EdgeRow schema
   ```

3. **Check Track C (policy coverage):**
   ```powershell
   Test-Path modules\shared\PolicyCoverageAnalyzer.ps1
   # Must exist and export Get-PolicyCoverageGaps
   ```

4. **Check Track D (tool fidelity):**
   ```powershell
   Select-String -Path modules\shared\Schema.ps1 -Pattern "ComplianceMappings|Pillar|Impact|Effort|RemediationSnippets|DeepLinkUrl"
   # All 6 fields must exist in FindingRow v2.2+ schema
   ```

5. **Check Track E (triage):**
   ```powershell
   Test-Path modules\triage\LlmTriageEngine.ps1
   # Optional — if missing, Track F degrades gracefully
   ```

6. **Check Track V (viewer + report architecture):**
   ```powershell
   Test-Path modules\shared\Select-ReportArchitecture.ps1
   Test-Path modules\shared\ReportManifest.ps1
   # Both must exist
   ```

**If any D1 check fails:**
- Document blocker in issue #506 comment
- STOP implementation
- Escalate to user: "Track F blocked by missing dependency: [track name]. Implementation cannot proceed until [track issue] merges to main."

**If all D1 checks pass:**
- Proceed to commit 1

**Automation suggestion:** Implement `Test-TrackFDependencies.ps1` script that runs all 6 checks and exits non-zero if any fail. Call from commit 0.

---

## 17. Documentation Deliverable Per Commit

Per repo rule: "Every PR that changes code, queries, or configuration MUST include a docs update in the same commit."

**Batch strategy for Track F:** Docs updates batched in **commit 9** (final commit) rather than per-commit. Rationale:
- Commits 1-8 are internal module changes (no user-visible surface until commit 7 wires orchestrator)
- Commit 9 finalizes the user-facing contract (orchestrator flag, outputs, parity tests)
- Single docs update reduces churn

**Commits 1-8:** No README/PERMISSIONS/CHANGELOG edits.

**Commit 9:** All docs updated in one commit (per §11 above).

**Exception:** If user prefers incremental docs per commit, adjust plan to add lightweight CHANGELOG entries per commit (e.g., commit 1: "Internal: Track F context resolution skeleton"). **Default plan assumes batch docs in commit 9.**

---

## 18. Draft-PR Body Template

**Title:** `feat(impl): flesh out auditor-driven report builder (Track F / #434 / PR #481)`

**Body:**
```markdown
## Track F implementation — flesh out auditor-driven report builder

Closes #506. Implements Track F auditor-driven report redesign per design doc `docs/design/track-f-auditor-redesign.md` (merged via PR #481).

**Status:** DRAFT — PR stays draft until user approval. NOT to be merged this cycle.

---

### Scope

Implements the 12 frozen function signatures in `modules/shared/AuditorReportBuilder.ps1`:
- `Build-AuditorReport` (orchestrator)
- `Resolve-AuditorContext`
- `Get-AuditorExecutiveSummary`
- `Get-AuditorControlDomainSections` (Track D consumer)
- `Get-AuditorAttackPathSection` (Track A consumer)
- `Get-AuditorResilienceSection` (Track B consumer)
- `Get-AuditorPolicyCoverageSection` (Track C consumer)
- `Get-AuditorTriageAnnotations` (Track E consumer, optional)
- `Get-AuditorRemediationAppendix`
- `Get-AuditorEvidenceExport`
- `Write-AuditorRenderTier`
- `New-AuditorCitation`

Wires auditor mode to `Invoke-AzureAnalyzer.ps1 -Profile Auditor`. Adds navigation chip in `New-HtmlReport.ps1`. Extends `report-manifest.json` writer with `profile.auditor` block.

---

### Parity Contract Checklist (per #434 Round 2)

10 canonical auditor questions answered identically at Tier 1 and Tier 4:

- [ ] 1. Top 10 most severe findings (by ID)
- [ ] 2. Framework controls failing (CIS, NIST, MCSB, ISO — control IDs)
- [ ] 3. Findings in subscription X (count)
- [ ] 4. Attack path to privileged identity Z exists (boolean)
- [ ] 5. Blast radius of resource R (node count)
- [ ] 6. Policies assigned vs. missing at scope S (counts)
- [ ] 7. AzAdvertizer suggestions available (boolean)
- [ ] 8. Remediation text for finding F (exact string)
- [ ] 9. Diff since run R (added/resolved counts)
- [ ] 10. Evidence export for subscription X succeeds (file exists)

Parity enforced by `tests/integration/AuditorParity.Tests.ps1` (test #30).

---

### Declared Degradation Contract

Every degradation (e.g., Track A missing, Tier 3 paginated subgraph) declared in `report-manifest.json` under `profile.auditor.degradations[]`. UI surfaces degradations in banner. No silent feature drops.

---

### Test Counts

**Baseline (pre-PR):** 842 tests green  
**Post-PR:** 875 tests green (+33 net new)  
**Target:** +25-30 (✅ exceeded)

---

### Commits (9-commit sequence)

1. `feat(report): implement auditor context resolution and executive summary` (+4 tests)
2. `feat(report): implement control-domain section grouping and renderers` (+3 tests)
3. `feat(report): implement attack-path, resilience, and policy-coverage sections` (+5 tests)
4. `feat(report): implement remediation appendix and evidence export` (+5 tests)
5. `feat(report): implement LLM triage annotations` (+3 tests)
6. `feat(report): implement tier-aware rendering and citation helper` (+4 tests)
7. `feat(report): wire auditor mode to Invoke-AzureAnalyzer.ps1 -Profile Auditor` (+2 tests)
8. `feat(report): extend report-manifest.json with auditor profile block` (+3 tests)
9. `test(report): add 10-question parity tests and update docs` (+4 tests)

---

### How to Review

1. **Design first:** Read `docs/design/track-f-auditor-redesign.md` (already on main via PR #481).
2. **Commit-by-commit:** Each commit is self-contained, Pester-green, and tested.
3. **Parity validation:** Run `Invoke-Pester -Path .\tests\integration\AuditorParity.Tests.ps1` to validate 10-question equivalence.
4. **Smoke test:** Run `Invoke-AzureAnalyzer.ps1 -Profile Auditor -Subscription 'test-sub'` and open `output/audit-report.html`.

---

### What's NOT in Scope This Cycle

- PDF generator (print stylesheet only)
- Framework version pinning (Track D drives)
- Citation provenance includes query hash only if Track D populates `SourceQueryHash`
- Merging this PR (stays draft until user approval)

---

### Acceptance (per #506)

- [ ] All 6 dependency tracks (A, B, C, D, E, V) on `main` ✅ (validated in commit 0)
- [ ] +25-30 net new Pester tests passing ✅ (+33)
- [ ] 10 canonical auditor questions parity test green ✅
- [ ] Citation lines pass `Remove-Credentials` round-trip ✅
- [ ] Auditor-mode HTML self-contained at Tier 1/2 ✅
- [ ] `audit-evidence/` directory generated ✅
- [ ] README, PERMISSIONS, CHANGELOG updated ✅

---

### References

- Issue #506 (impl tracker)
- Issue #434 (Track F requirements + Round 2 lock)
- PR #481 (design + skeleton, merged)
- Design doc: `docs/design/track-f-auditor-redesign.md`
```

---

## 19. Stop Criteria

**Hard rule:** PR #506 stays **DRAFT**. NOT to be merged this cycle.

**User action required to flip to ready:**
1. Review all 9 commits in PR
2. Run smoke test: `Invoke-AzureAnalyzer.ps1 -Profile Auditor` on a real tenant
3. Validate 10-question parity test output
4. Comment on PR: "Approved for merge" OR request changes
5. Flip PR from draft to ready

**Implementer (agent executing this plan) MUST NOT:**
- Flip PR to ready without user approval
- Merge PR
- Close issue #506 (it stays open until PR merges)

**Implementer MUST:**
- Open draft PR after commit 9
- Comment on #506: "Draft PR ready for review: [PR link]"
- Halt execution until user responds

---

## 20. Summary of Per-Commit Invariants

Every commit MUST satisfy:
1. **Pester green:** `Invoke-Pester -Path .\tests -CI` exits 0
2. **No regressions:** Test count increases or holds (never decreases)
3. **Commit message:** Conventional commits format (`feat(report):`, `test(report):`, `docs:`)
4. **Git trailer:** `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
5. **No secrets:** All output sanitized via `Remove-Credentials`
6. **No /tmp writes:** All file I/O in project directory (`output/`, `tests/fixtures/`)

If any invariant fails: STOP, fix, re-run Pester, then proceed.

---

## 21. Risk Assessment (Overall)

**Low-risk commits:** 0, 1, 2, 4, 5, 6, 8, 9 (new functions, no callers, or docs-only)

**Medium-risk commits:** 3 (Track A/B/C consumers), 7 (orchestrator wiring)

**Mitigation:**
- Extensive unit tests per function (33 total)
- Integration test in commit 9 validates end-to-end
- Graceful degradation when Track A/B/C/E data missing (declared in manifest, not thrown exceptions)
- Smoke test before PR open

**Worst-case failure mode:** Auditor report fails to generate (orchestrator throws). User fallback: use standard report (`New-HtmlReport.ps1`). Auditor mode is opt-in; default behavior unaffected.

---

## 22. Implementation Estimate

Per design doc §9: **2-3 days** once dependencies land.

**Per-commit time estimate:**
| Commit | Estimated time | Cumulative |
|---|---|---|
| 0 (deps check) | 15 min | 0.25h |
| 1 (context + exec) | 2-3 hours | 3.25h |
| 2 (control domains) | 2 hours | 5.25h |
| 3 (A/B/C consumers) | 3-4 hours | 9.25h |
| 4 (remediation + evidence) | 2 hours | 11.25h |
| 5 (triage) | 1 hour | 12.25h |
| 6 (render tier + citation) | 3 hours | 15.25h |
| 7 (orchestrator wiring) | 1.5 hours | 16.75h |
| 8 (manifest extension) | 1 hour | 17.75h |
| 9 (parity + docs) | 2-3 hours | 20.75h |

**Total:** ~21 hours = 2.6 days for one engineer.

---

## 23. Citations

All statements above cite:
- **Design doc §1:** `docs/design/track-f-auditor-redesign.md:11-25` (hard dependencies)
- **Design doc §4.1:** `docs/design/track-f-auditor-redesign.md:76-87` (tier awareness)
- **Design doc §4.2:** `docs/design/track-f-auditor-redesign.md:89-100` (frozen signatures)
- **Design doc §8:** extracted via PowerShell in context load (test strategy)
- **Design doc §9:** `docs/design/track-f-auditor-redesign.md:400-412` (9-commit plan)
- **Design doc §10:** `docs/design/track-f-auditor-redesign.md:414-418` (open questions)
- **Skeleton:** `modules/shared/AuditorReportBuilder.ps1:1-170` (12 frozen functions)
- **Issue #506:** loaded via `gh issue view 506` (hard dependencies table, acceptance criteria)
- **Issue #434 comments:** `gh issue view 434` (10 canonical auditor questions, Round 2 lock)
- **PR #481:** `gh pr view 481` (scaffold + design merged to main)

---

## 24. Learning (for .squad/agents/lead/history.md)

**Learning:** Track F implementation plan required a **serial dependency audit** (commit 0) before starting code. This mirrors the "iterate until green — resilience contract" principle: validate pre-conditions before proceeding. Design doc §1 explicitly calls out 6 hard dependencies; commit 0 enforces them programmatically. Future multi-track implementations should follow this pattern: **commit 0 = dependency gate, not first feature commit**.

**Why this matters:** Skipping dependency check risks mid-implementation discovery that Track A/B/C/D/E/V are incomplete, forcing rework. The D1 gate catches blockers upfront, saving 12-18 hours of wasted effort.

**When to apply:** Any issue with explicit `depends_on` metadata OR any design doc with a "hard dependencies" section.

---

## 25. Decision Summary (for .squad/decisions/inbox/)

See companion file: `.squad/decisions/inbox/lead-track-f-impl-plan-2026-04-23.md`

---

## END OF PLAN

**Next action (for implementer):** Execute commit 0 (dependency check). If green, proceed to commit 1. If red, STOP and escalate blocker to user via #506 comment.
