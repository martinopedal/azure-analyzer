# Track F - Auditor-Driven Report Redesign (Design)

**Status:** DRAFT - design + skeleton only. No implementation in this PR.
**Issue:** [#434](https://github.com/martinopedal/azure-analyzer/issues/434) (Track F of epic [#427](https://github.com/martinopedal/azure-analyzer/issues/427)).
**Author:** Atlas (Azure Resource Graph Engineer / Lead).
**Authority:** RESEARCH-AND-DRAFT. Implementation is held until Tracks A-E + V land.
**Scope decision:** The Lead 8-hour close plan (recorded in PR #481) closes #434 as `defer-post-epic`. This document is the code-ready proposal so the next agent can ship Track F in **days, not weeks**, once the upstream tracks merge.

---

## 1. Hard dependencies (must land first)

Track F is the **serial tail** of the epic. It cannot start until every dependency below is merged on `main`:

| Track | Issue | What Track F consumes from it | Why it blocks Track F |
|---|---|---|---|
| **A** - attack paths | #428 / PR #440 | `EdgeRelations` enum + attack-path edges in `entities.json` | Powers the *Attack Path* control-domain section and the auditor question "what is the path to privileged identity Z?" |
| **B** - resilience maps | #429 / PR #436 | Blast-radius edges + resilience scoring | Powers the *Resilience / Blast Radius* section and the question "what is the blast radius of resource R?" |
| **C** - policy enforcement & gaps | #431 / PR #444 | Policy-assignment vs. ALZ-reference deltas | Powers the *Policy Coverage* section and "which policies are missing at scope S?" |
| **D** - tool-output fidelity | #432a (skeleton) + #432b/#432c (post-window) | Per-tool `ComplianceMappings`, `Pillar`, `Impact`, `Effort`, `RemediationSnippets`, `DeepLinkUrl` populated by every normalizer | Powers the compliance dashboard and the "ready to remediate" appendix. **Without #432b/c the dashboard renders mostly empty cells.** |
| **E** - LLM triage | #433 (superseded by #466) / #462 flesh-out | Triage verdicts (`triage.json`) + rationale + suggested suppression | Powers the *Triage Panel* and the optional "auditor cross-check" annotations. |
| **V** - 4-tier viewer + report architecture | #430 (superseded by #467) + foundation #435 | `Select-ReportArchitecture`, `report-manifest.json`, `Test-ReportFeatureParity` | Track F renders **into** the architecture chosen by Track V. We never invent a tier; we register feature blocks in `report-manifest.json`. |
| **Foundation** | #435 (MVP merged via PR #456) | `EdgeRelations` enum (16 values), `report-manifest.json` v1, dual-read entity store | Schema substrate for everything above. |

Implementation starts on the day all of the above are on `main` and the Pester baseline is green.

## 2. Goals (auditor lens)

The current report (`New-HtmlReport.ps1` v2) is **finding-centric**: a sortable table with filter chips. An auditor needs a **control-centric** view with evidence-grade citations. The 60-second auditor checklist from #434 is the acceptance contract:

1. Identify the 10 most severe findings.
2. See which framework controls are failing (CIS, NIST, MCSB, ISO 27001, PCI).
3. Export evidence for a specific subscription / management group.
4. See which MG-scoped policies are missing vs. ALZ reference.
5. Identify an attack path to a privileged identity.
6. Copy a finding citation for the audit workpaper.

Track F adds an **auditor mode** to the existing reports. Default (developer) mode is unchanged; auditor mode is opt-in via `-Profile Auditor` on `Invoke-AzureAnalyzer.ps1`, surfaced in `report-manifest.json` as `profile: "auditor"`.

## 3. Non-goals

- Replacing `New-HtmlReport.ps1` / `New-MdReport.ps1` / `New-ExecDashboard.ps1`. Those remain the developer-default outputs.
- Inventing new schema fields. Track F **only consumes** what Tracks A-E + V populate. If a field is missing, the section degrades per `report-manifest.json` declared-degradation rules.
- Re-implementing rendering primitives. Track F builds on top of `modules/shared/ExecDashboardRender.ps1` and the v2 HTML helpers in `New-HtmlReport.ps1`.

## 4. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Invoke-AzureAnalyzer.ps1  -Profile Auditor                     │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
        ┌────────────────────────────────────────────┐
        │  modules/shared/AuditorReportBuilder.ps1   │ ◀── NEW (this PR: skeleton only)
        │                                            │
        │  Build-AuditorReport                       │  orchestrator entry
        │   ├─ Resolve-AuditorContext                │  scope + tier + manifest
        │   ├─ Get-AuditorExecutiveSummary           │  scope, methodology, counts
        │   ├─ Get-AuditorControlDomainSections      │  CIS / NIST / MCSB / ISO
        │   ├─ Get-AuditorAttackPathSection          │  Track A consumer
        │   ├─ Get-AuditorResilienceSection          │  Track B consumer
        │   ├─ Get-AuditorPolicyCoverageSection      │  Track C consumer
        │   ├─ Get-AuditorTriageAnnotations          │  Track E consumer (optional)
        │   ├─ Get-AuditorRemediationAppendix        │  groups by Remediation
        │   ├─ Get-AuditorEvidenceExport             │  CSV / JSON / XLSX
        │   └─ Write-AuditorRenderTier               │  HTML / MD / PDF print css
        └────────────────────────────────────────────┘
                             │
       ┌─────────────────────┼─────────────────────┐
       ▼                     ▼                     ▼
   audit-report.html    audit-report.md    audit-evidence/*.csv
   (tier-aware)         (prose-heavy)       *.json, *.xlsx
```

### 4.1 Tier awareness (Track V contract)

Track F **must not** invent its own tier picker. It calls `Select-ReportArchitecture` (from foundation #435 / PR #456) and renders per the chosen tier. Per #434 Round 2 lock, parity is **question parity with declared degradation**, not pixel parity.

| Tier | Rendering of auditor sections | Declared degradation |
|---|---|---|
| **Tier 1 - PureJson (≤10k findings)** | Prose-heavy. Full executive narrative (3-4 paragraphs). Each control domain has full finding tables inline. Compliance heatmap rendered as inline SVG. | none |
| **Tier 2 - EmbeddedSqlite (10k-50k)** | Prose summary + sortable tables fed from embedded SQLite via `sql.js`. Heatmap inline SVG. | `tables.virtualized` (rows beyond viewport are paginated). |
| **Tier 3 - SidecarSqlite (50k-240k)** | Executive summary + control-domain *headlines* with "Open in viewer" deep link. No inline finding tables. | `tables.sidecar`, `attackPath.paginatedSubgraph`, `evidence.exportOnly` (no in-page download; `audit-evidence/` directory shipped alongside report). |
| **Tier 4 - PodeViewer (>240k)** | Executive summary + KPI tiles + deep links into the Pode viewer. Control domains rendered as tile grid. | `attackPath.serverQueriedNeighborhood`, `compliance.aggregatedCounts`, `evidence.serverStreamed`. |

All degradations are written to `report-manifest.json` under `report.profile.auditor.degradations[]` per Track V lock and surface in the report's degradation banner.

### 4.2 Module surface (decided)

`modules/shared/AuditorReportBuilder.ps1` exposes the following functions. Signatures are **frozen** by this PR. Implementations throw `[NotImplementedException]` and are tested behind `-Skip` placeholders, preserving the Pester baseline (≥1637 total, ≥1602 passed).

```powershell
Build-AuditorReport
  -InputPath          <string>   # path to results.json (FindingRow array)
  -EntitiesPath       <string>   # path to entities.json (v3)
  -ManifestPath       <string>   # path to report-manifest.json
  -TriagePath         <string>   # optional triage.json
  -PreviousRunPath    <string>   # optional prior results for diff mode
  -OutputDirectory    <string>   # writes audit-report.html|.md + audit-evidence/
  -Profile            <string>   # 'auditor' (only value for now; future: 'soc', 'ciso')
  -ControlFrameworks  <string[]> # default @('CIS','NIST','MCSB','ISO27001')
  -Tier               <string>   # PureJson|EmbeddedSqlite|SidecarSqlite|PodeViewer
                                 # (resolved via Select-ReportArchitecture if omitted)
  -CitationStyle      <string>   # 'inline' | 'footnote' | 'workpaper'
  -PassThru           <switch>   # return the assembled context object
```

Internal (dot-sourced; not exported):

| Function | Returns | Consumes from tracks |
|---|---|---|
| `Resolve-AuditorContext` | hashtable: `Tier`, `Manifest`, `Findings`, `Entities`, `Triage`, `Previous`, `RunId`, `Scopes` | foundation #435, V #430 |
| `Get-AuditorExecutiveSummary` | hashtable: `ScopeStatement`, `Methodology`, `SeverityCounts`, `ControlCoveragePct`, `TopRisks` | D, E |
| `Get-AuditorControlDomainSections` | hashtable[]: one per framework with `Controls`, `FindingsByControl`, `CoverageBar` | D (`ComplianceMappings`) |
| `Get-AuditorAttackPathSection` | hashtable: `Paths`, `PrivilegedTargets`, `RenderingMode` | A |
| `Get-AuditorResilienceSection` | hashtable: `BlastRadius`, `Top10Exposed`, `RenderingMode` | B |
| `Get-AuditorPolicyCoverageSection` | hashtable: `AssignedVsReference`, `AlzGaps`, `RecommendedRemediations` | C |
| `Get-AuditorTriageAnnotations` | hashtable: `VerdictByFinding`, `SuggestedSuppressions` | E (optional, gated on `triage.json`) |
| `Get-AuditorRemediationAppendix` | hashtable: `GroupsByRemediation` ordered by aggregate severity | D |
| `Get-AuditorEvidenceExport` | string[]: written file paths | (none - pure transform) |
| `Write-AuditorRenderTier` | string[]: written file paths | V |
| `New-AuditorCitation` | string: e.g. `[azqr v1.5.0] F-12345: ...` | D |

### 4.3 File outputs

```
output/
├─ results.json                     (existing, untouched)
├─ entities.json                    (existing, untouched)
├─ report-manifest.json             (Track V; F appends profile.auditor block)
├─ report.html                      (existing developer view, untouched)
├─ dashboard.html                   (existing exec view, untouched)
├─ audit-report.html                ← NEW
├─ audit-report.md                  ← NEW
└─ audit-evidence/                  ← NEW
   ├─ findings-all.csv
   ├─ findings-all.json
   ├─ findings-all.xlsx             (only if ImportExcel module present; else .csv only)
   ├─ findings-by-subscription/<sub>.csv
   ├─ findings-by-framework/<framework>.csv
   └─ citations.txt                 (one line per finding, workpaper-paste ready)
```

`audit-report.html` is **self-contained** at Tier 1 and Tier 2 (inline CSS/JS, no CDN), per existing convention in `New-HtmlReport.ps1`. At Tier 3/4, it deep-links into the sidecar SQLite or Pode viewer.

## 5. Mock JSON shapes

### 5.1 `report-manifest.json` - auditor profile block (added by Track F)

```jsonc
{
  "report": {
    "manifestVersion": "1.0",
    "tier": "EmbeddedSqlite",
    "profile": {
      "auditor": {
        "schemaVersion": "1.0",
        "generatedAt": "2026-05-01T08:00:00Z",
        "runId": "run-2026-05-01-0800",
        "previousRunId": "run-2026-04-24-0800",
        "controlFrameworks": ["CIS", "NIST", "MCSB", "ISO27001"],
        "scopeStatement": "Tenant 11111111-...; 4 management groups; 17 subscriptions; 9,412 resources.",
        "methodology": "Azure Resource Graph snapshot + 12 enabled scanners (azqr, kubescape, ...). See tools/tool-manifest.json for the exact pin matrix.",
        "outputs": {
          "html": "audit-report.html",
          "md": "audit-report.md",
          "evidenceDir": "audit-evidence/"
        },
        "sections": [
          { "id": "exec",        "title": "Executive Summary",      "renderingMode": "prose"            },
          { "id": "control.cis", "title": "CIS Azure 2.1 Coverage", "renderingMode": "table+heatmap"    },
          { "id": "control.nist","title": "NIST 800-53 Coverage",   "renderingMode": "table+heatmap"    },
          { "id": "control.mcsb","title": "Microsoft Cloud Security Benchmark", "renderingMode": "table+heatmap" },
          { "id": "control.iso", "title": "ISO 27001:2022 Annex A", "renderingMode": "table+heatmap"    },
          { "id": "attackpath",  "title": "Attack Paths",           "renderingMode": "paginated-subgraph" },
          { "id": "resilience",  "title": "Blast-Radius / Resilience", "renderingMode": "table"          },
          { "id": "policy",      "title": "Policy Coverage vs. ALZ", "renderingMode": "table"           },
          { "id": "remediation", "title": "Ready to Remediate",     "renderingMode": "grouped-list"     },
          { "id": "evidence",    "title": "Evidence Export",        "renderingMode": "sidecar-files"    }
        ],
        "degradations": [
          {
            "feature": "tables.virtualized",
            "tier1Mode": "full-html-table",
            "thisTierMode": "sql.js-paginated",
            "reason": "240k+ rows would exceed 2 MB page-weight budget."
          }
        ]
      }
    }
  }
}
```

### 5.2 Internal section shape (executive summary)

```jsonc
{
  "scopeStatement": "Tenant ..., 17 subscriptions, 9412 resources",
  "methodology":    "ARG + 12 scanners (azqr, kubescape, kube-bench, ...)",
  "severityCounts": { "Critical": 8, "High": 142, "Medium": 433, "Low": 1290, "Info": 7521 },
  "controlCoveragePct": {
    "CIS":       { "covered": 142, "total": 173, "pct": 82.1 },
    "NIST":      { "covered":  78, "total": 130, "pct": 60.0 },
    "MCSB":      { "covered":  91, "total":  99, "pct": 91.9 },
    "ISO27001":  { "covered":  48, "total":  93, "pct": 51.6 }
  },
  "topRisks": [
    { "id": "F-12345", "title": "...", "severity": "Critical",
      "entity": "/subscriptions/.../keyVaults/kv-prod-01",
      "framework": "CIS 2.1.4", "remediation": "Enable purge protection",
      "citation": "[azqr v1.5.0] F-12345: ..." }
  ],
  "diff": { "previousRunId": "run-2026-04-24-0800", "added": 12, "resolved": 34, "changedSeverity": 5 }
}
```

### 5.3 Control-domain section (CIS example)

```jsonc
{
  "framework": "CIS",
  "frameworkVersion": "Azure 2.1",
  "controls": [
    {
      "id": "CIS 2.1.4",
      "title": "Ensure Key Vault purge protection is enabled",
      "status": "fail",
      "findingCount": 8,
      "severityRollup": "High",
      "topFindings": ["F-12345", "F-12346"],
      "remediation": "Set EnablePurgeProtection=true on listed Key Vaults.",
      "evidenceCitation": "[azqr v1.5.0] CIS 2.1.4: 8 of 11 Key Vaults non-compliant."
    }
  ],
  "coverageBar": { "pass": 142, "fail": 24, "manual": 7, "notApplicable": 0 }
}
```

## 6. Layout sketches (ASCII)

### 6.1 Tier 1 - `audit-report.html` (prose-heavy)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ azure-analyzer · Audit Report · Tenant 1111…  · run-2026-05-01-0800         │
│ ─────────────────────────────────────────────────────────────────────────── │
│ [ Executive Summary ] [ CIS ] [ NIST ] [ MCSB ] [ ISO ] [ AttackPath ]      │
│ [ Resilience ] [ Policy ] [ Remediation ] [ Evidence ↓ ]   🌙 Dark   🖨 Print│
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. EXECUTIVE SUMMARY                                                         │
│    Scope:        Tenant 1111…, 4 MGs, 17 subscriptions, 9,412 resources.    │
│    Methodology:  ARG snapshot + 12 enabled scanners (see tool pin matrix).  │
│    Period:       2026-05-01T08:00Z (compared to run-2026-04-24-0800Z).      │
│                                                                              │
│    Findings by severity                                                      │
│    ╔═══════════╤═══════╤════════════════════════════════════════════════╗   │
│    ║ Critical  │   8   │ ████                                            ║   │
│    ║ High      │ 142   │ ████████████████████████                        ║   │
│    ║ Medium    │ 433   │ ████████████████████████████████████████        ║   │
│    ║ Low       │1,290  │ ████████████████████████████████████████████    ║   │
│    ║ Info      │7,521  │ (suppressed in evidence export)                ║   │
│    ╚═══════════╧═══════╧════════════════════════════════════════════════╝   │
│                                                                              │
│    Control coverage vs. four reference frameworks                           │
│    CIS Azure 2.1            ▓▓▓▓▓▓▓▓░░  82%   142/173  controls evaluated   │
│    NIST 800-53 r5           ▓▓▓▓▓▓░░░░  60%    78/130                       │
│    MCSB v1                  ▓▓▓▓▓▓▓▓▓░  92%    91/99                        │
│    ISO 27001:2022 Annex A   ▓▓▓▓▓░░░░░  52%    48/93                        │
│                                                                              │
│    Δ since previous run: +12 findings, −34 resolved, 5 severity changes.    │
├─────────────────────────────────────────────────────────────────────────────┤
│ 2. TOP 10 RISKS                            [ Copy all citations 📋 ]        │
│    1.  🔴 F-12345  Key Vault purge protection disabled  · CIS 2.1.4         │
│        kv-prod-01    Severity High · Effort Low                             │
│        Citation: [azqr v1.5.0] F-12345: 8 of 11 Key Vaults non-compliant…   │
│        [ Copy citation 📋 ]   [ View finding ]   [ View remediation ]       │
│    …                                                                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Control-domain section (CIS, all tiers)

```
┌─ 3. CIS Azure 2.1 ──────────────────────────────────────────────────────────┐
│  Coverage bar:  pass 142 │ fail 24 │ manual 7 │ n/a 0           [ CSV ↓ ]   │
│                                                                              │
│  Control                                            Status   Count  Sev     │
│  ─────────────────────────────────────────────────  ──────   ─────  ───     │
│  1.1.1  Ensure that multi-factor authentication is  FAIL       12   High    │
│         enabled for all privileged users                                     │
│  2.1.4  Ensure Key Vault purge protection is        FAIL        8   High    │
│         enabled                                                              │
│  3.1    Ensure Microsoft Defender for Cloud is on   PASS        0   -       │
│  …                                                                           │
│                                                                              │
│  Heatmap: control × subscription                                             │
│       sub-prod  sub-stage  sub-dev  sub-sandbox                              │
│  1.1.1  ▓▓▓▓     ▓▓░░       ░░░░     ░░░░                                    │
│  2.1.4  ▓▓░░     ▓░░░       ░░░░     ░░░░                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Ready-to-remediate appendix

```
┌─ 9. READY TO REMEDIATE ─────────────────────────────────────────────────────┐
│  Grouped by remediation text, ordered by aggregate severity weight.          │
│                                                                              │
│  ▼ Enable Key Vault purge protection                       8 findings · High │
│       Az CLI:                                                                │
│       az keyvault update --name <name> --enable-purge-protection true        │
│       Affected: kv-prod-01, kv-prod-02, … (8)              [ Copy snippet 📋]│
│                                                                              │
│  ▼ Enforce HTTPS-only on storage accounts                 23 findings · High │
│       Bicep snippet, az CLI snippet, Terraform snippet - all from           │
│       FindingRow.RemediationSnippets[].                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.4 Tier 4 (PodeViewer) - KPI tiles only

```
┌─ Audit Report · Tier 4 (PodeViewer) ────────────────────────────────────────┐
│  ⚠ This tenant has 312,415 findings. Inline tables are disabled at Tier 4.  │
│    Open the live viewer to drill down.                  [ Open viewer ↗ ]    │
│                                                                              │
│  ┌─ Critical ─┐ ┌─ High ─┐ ┌─ CIS Pass ─┐ ┌─ NIST Pass ─┐ ┌─ Δ since prev ─┐│
│  │     142    │ │  3,402 │ │   71.4 %   │ │    58.2 %   │ │  +312 / −1,201 ││
│  └────────────┘ └────────┘ └────────────┘ └─────────────┘ └────────────────┘│
│                                                                              │
│  Control domains   →   open in viewer                                        │
│  CIS Azure 2.1            ▓▓▓▓▓▓▓░░░  71%       [ Drill-down ↗ ]            │
│  NIST 800-53 r5           ▓▓▓▓▓▓░░░░  58%       [ Drill-down ↗ ]            │
│  MCSB v1                  ▓▓▓▓▓▓▓▓▓░  91%       [ Drill-down ↗ ]            │
│  ISO 27001:2022 Annex A   ▓▓▓▓▓░░░░░  49%       [ Drill-down ↗ ]            │
│                                                                              │
│  Evidence export streamed from sidecar:  audit-evidence/  (downloaded sep.)  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 7. Tier-aware behavior matrix

| Section | Tier 1 (PureJson) | Tier 2 (EmbeddedSqlite) | Tier 3 (SidecarSqlite) | Tier 4 (PodeViewer) |
|---|---|---|---|---|
| Executive summary prose | full | full | full | KPI tiles + 1-paragraph |
| Severity counts | inline SVG bar | inline SVG bar | inline SVG bar | KPI tile |
| Control-domain tables | inline | sql.js paginated | headline + deep link | tile + deep link |
| Compliance heatmap | inline SVG | inline SVG | static PNG snapshot | static PNG snapshot |
| Attack-path | full Cytoscape | paginated Cytoscape | paginated subgraph | server-queried neighborhood |
| Remediation appendix | inline grouped list | inline grouped list | top-20 + deep link | top-10 tile |
| Evidence export | inline download | inline download | sidecar dir | sidecar dir streamed |
| Diff vs. previous run | inline | inline | inline | KPI tile |
| Print stylesheet | full PDF | full PDF | summary-only PDF | summary-only PDF |

Every cell in this matrix corresponds to one entry under `report.profile.auditor.degradations[]` when the rendering mode differs from Tier 1. This is the **declared-degradation contract** locked in #434 Round 2.

## 8. Test strategy

All tests live under `tests/` and follow the existing Pester v5 conventions. **Skeleton tests in this PR are `-Skip`** so the Pester baseline is maintained (≥1637 total, ≥1602 passed).

### 8.1 Unit (tests/shared/AuditorReportBuilder.Tests.ps1) - NEW

| Test | Asserts |
|---|---|
| `Build-AuditorReport throws NotImplementedException today` | Skeleton-honesty test (drops once implemented). |
| `Resolve-AuditorContext reads report-manifest.json tier` | Tier from manifest takes precedence over `-Tier` param when both present. |
| `Get-AuditorExecutiveSummary computes severity counts from FindingRow[]` | Counts match `Group-Object Severity`. |
| `Get-AuditorExecutiveSummary computes control coverage from ComplianceMappings` | Per-framework `covered/total/pct` calculation. |
| `Get-AuditorControlDomainSections groups findings by framework control id` | One section per requested framework. |
| `Get-AuditorRemediationAppendix groups by exact Remediation text and orders by severity weight` | Stable ordering, deterministic grouping. |
| `New-AuditorCitation produces single-line workpaper-ready string` | Format: `[<source> <pin>] <id>: <title>. Resource: <canonical>. Severity: <sev>. Collected <iso>. Rule: <url>. Docs: <url>.`. |
| `Get-AuditorEvidenceExport writes CSV/JSON; XLSX only when ImportExcel present` | Conditional output, sanitized via `Remove-Credentials`. |

### 8.2 Parity / contract (tests/integration/AuditorParity.Tests.ps1) - NEW

| Test | Asserts |
|---|---|
| 10 canonical auditor questions answered identically at Tier 1 and Tier 4 | Snapshot equivalence on the *answer*, not the *rendering* (per Round 2 lock). |
| Every section in `report.profile.auditor.sections` has a declared `renderingMode` at the chosen tier | Catalog-feature parity. |
| Every degradation in `report.profile.auditor.degradations[]` references a real section id | No orphan degradation records. |
| Citation lines pass `Remove-Credentials` round-trip without modification | Output sanitization. |

### 8.3 Fixtures

Reuse `tests/fixtures/Generate-SyntheticFixture.ps1` (foundation #435). Track F adds two profiles:
- `auditor-small` - 200 findings, all four frameworks present, used by Tier 1 tests.
- `auditor-jumbo` - 250k findings, used by Tier 3/4 parity tests.

Both written deterministically (seeded RNG).

### 8.4 Pester baseline impact

- **This PR (skeleton):** +1 file, all tests `-Skip`, baseline preserved (no failing assertions).
- **Implementation PR:** target +25-30 new passing tests, no regressions.

## 9. Implementation plan (post-dependency)

Once Tracks A-E + V are on `main`, execute in this order. Each step is a separate commit; the whole sequence ships in one PR (Track F is small once dependencies land).

1. Implement `Resolve-AuditorContext` + `Get-AuditorExecutiveSummary` + skeleton tests pass. Drop `-Skip`.
2. Implement `Get-AuditorControlDomainSections` (D consumer). Add CIS/NIST/MCSB/ISO renderers in HTML and MD.
3. Implement `Get-AuditorAttackPathSection` + `Get-AuditorResilienceSection` + `Get-AuditorPolicyCoverageSection` (A/B/C consumers).
4. Implement `Get-AuditorRemediationAppendix` + `Get-AuditorEvidenceExport`.
5. Implement `Get-AuditorTriageAnnotations` (E consumer, optional).
6. Implement `Write-AuditorRenderTier`: HTML for Tier 1/2, headline+deep-link for Tier 3, KPI-tile for Tier 4. Print stylesheet for all tiers.
7. Wire `Invoke-AzureAnalyzer.ps1 -Profile Auditor` to call `Build-AuditorReport`. Update `New-HtmlReport.ps1` only to inject the navigation chip "Audit view ↗" when `audit-report.html` exists.
8. Update `report-manifest.json` writer (foundation #435) to append the `report.profile.auditor` block.
9. Update README + PERMISSIONS.md + CHANGELOG.md.

Estimated implementation effort once dependencies land: **2-3 days** for one engineer (vs. 3+ weeks if everything is designed at the same time as it's coded).

## 10. Open questions for review

- **Citation provenance** - should the citation line include the exact ARG query hash (when source = ARG) so an auditor can replay the query? Lean **yes**; awaits Track D on whether `FindingRow.SourceQueryHash` will be populated.
- **PDF rendering** - print stylesheet only, or do we ship a real headless-Chromium PDF generator? Lean **print-stylesheet only** to avoid a heavy dependency.
- **Framework versions** - pin to a manifest (CIS Azure 2.1, NIST 800-53 r5, MCSB v1, ISO 27001:2022) or follow whatever Track D normalizers emit? Lean **Track D drives**; auditor mode renders whatever versions the data declares.

## 11. References

- Issue [#434](https://github.com/martinopedal/azure-analyzer/issues/434) - Track F requirements + Round 2 parity rule.
- Issue [#427](https://github.com/martinopedal/azure-analyzer/issues/427) - Epic Round 3 reconciliation.
- Lead 8-hour close plan (recorded in PR #481 description) - close plan and dependency call-out.
- `New-HtmlReport.ps1` - current v2 developer report (reused renderers).
- `New-MdReport.ps1` - Markdown report (reused MD helpers).
- `New-ExecDashboard.ps1` / `modules/shared/ExecDashboardRender.ps1` - single-page exec dashboard (KPI tile patterns).
- `modules/shared/Schema.ps1` - `New-FindingRow` and the v2.2 fields Track F consumes.
- `tools/tool-manifest.json` - `report` block per tool (color, phase) and frameworks list.
