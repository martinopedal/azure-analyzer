# Post-Ship Code Review: Track F (PRs #1086-#1097)

**Decision type:** Post-ship review
**Author:** Lead (squad review)
**Date:** 2026-05-14
**Scope:** Track F auditor report builder, commits 0-10, PRs #1086-#1097 (v1.5.2 to v1.6.1)
**Verdict:** 1 BUG (blocking), 2 RISKs (non-blocking), rest OK

---

## BUG-1: Findings key mismatch silently nulls downstream sections

**File:** `modules/shared/AuditorReportBuilder.ps1` line 120
**Severity:** HIGH
**Status:** Active in `main`

`Get-AuditorTriageAnnotations` returns key `AnnotatedFindings` (lines 551, 599).
`Build-AuditorReport` reads `$annotated.Findings` (line 120) -- the key does not exist.

```powershell
# Line 120 (current -- BUG)
$context['Findings'] = $annotated.Findings          # always $null

# Line 120 (fix)
$context['Findings'] = $annotated.AnnotatedFindings  # correct key
```

**Impact:** After the triage step, `$context['Findings']` becomes `$null`.
Every section that runs after triage receives null findings:

- `Get-AuditorRemediationAppendix` (line 127) -- empty remediation groups
- `Get-AuditorEvidenceExport` (line 131) -- CSV/JSON/XLSX with zero rows
- `Write-AuditorRenderTier` (line 135) -- HTML/MD findings table has one ghost row (`@($null)`)

The executive summary, control-domain sections, attack-path, resilience, and policy-coverage sections run *before* triage and are unaffected. So the report still generates, just with a broken second half.

**Why tests pass:** Test 32 checks for `F-\d+-F-001` in the HTML. This pattern matches because
Tier 1 HTML includes the findings table, which iterates `@($null)` (one null element).
In PowerShell, `$null.FindingId` returns `$null` (no StrictMode violation for property access).
The HTML cell renders as empty string `<td></td>`. The test's `Should -MatchExactly 'F-\d+-F-001'`
should FAIL because the pattern is not in the empty table. Either:

(a) CI does not run integration tests (only `Analyze (actions)` is a required check), or
(b) a fixture side-effect pre-populates the output directory from a prior test run.

Either way, the code-level bug is confirmed by reading the source.

**Fix:** One-line change at line 120.

---

## RISK-1: HTML interpolation without encoding

**File:** `modules/shared/AuditorReportBuilder.ps1` lines 821-824
**Severity:** LOW (defense-in-depth)

Finding fields are interpolated directly into HTML:

```powershell
<td>$($f.FindingId)</td>
<td class="$sevClass">$($f.Severity)</td>
<td>$($f.Title)</td>
<td>$($f.EntityId)</td>
```

If any field contains `<script>` or HTML entities, it renders as-is.
Not currently exploitable: findings come from internal JSON, not user web input.
But `Remove-Credentials` sanitization does not cover HTML entities.

**Suggested fix:** Add `[System.Web.HttpUtility]::HtmlEncode()` or a simple replace
for `<`, `>`, `&` before interpolation. Low urgency.

---

## RISK-2: Module wrapper lacks ValidateSet for -Profile

**File:** `AzureAnalyzer.psm1` line 143
**Severity:** LOW

The `.psm1` wrapper declares `[string] $Profile` without `[ValidateSet('Default','Auditor')]`.
The underlying `.ps1` script has the ValidateSet, so invalid values still error,
but the error message points at the script, not the module. Confusing for PSGallery users.

**Suggested fix:** Add `[ValidateSet('Default','Auditor')]` to the `.psm1` parameter.

---

## OK Items (no action required)

| Area | File | Notes |
|------|------|-------|
| ReportManifest -Profile/-Sections | `ReportManifest.ps1:263-311` | ValidateSet, casing-safe ID extraction, profile block attached correctly |
| PassThru semantics | `AuditorReportBuilder.ps1:58,160` | Orchestrator always passes `-PassThru $true`; no issue |
| Executive summary | `AuditorReportBuilder.ps1:207-288` | Severity grouping, framework coverage, diff summary all correct |
| Control domain grouping | `AuditorReportBuilder.ps1:290-333` | Regex-based ComplianceMappings match; frameworks configurable |
| Attack-path section | `AuditorReportBuilder.ps1:391-445` | Correct edge-relation filtering |
| Resilience section | `AuditorReportBuilder.ps1:447-492` | BlastRadiusScore iteration safe |
| Policy coverage | `AuditorReportBuilder.ps1:494-540` | Reads `Entities.policyGaps`; derives assigned count |
| Citation helper | `AuditorReportBuilder.ps1:900-966` | Evidence field deliberately excluded (credential safety) |
| Evidence export sanitization | `AuditorReportBuilder.ps1:667-723` | `Remove-Credentials` applied to all exports |
| Tier-aware rendering | `AuditorReportBuilder.ps1:725-898` | Print stylesheet, 4-tier layout, graceful fallback |
| README Auditor section | `README.md:82-106` | Accurate feature list, references design doc |
| CHANGELOG | `CHANGELOG.md:5-9,91-125` | All 10 commits documented with PR/SHA links |
| Parity tests | `tests/integration/AuditorParity.Tests.ps1` | 4 tests; Test 34b is `-Pending` (#1098) as expected |
| Orchestrator profile test | `tests/orchestrator/InvokeAzureAnalyzer.Profile.Tests.ps1` | Cross-platform temp dir; param validation tested |
| Redundant dot-source of Sanitize.ps1 | `AuditorReportBuilder.ps1:610-611,675-676` | Harmless; defensive against out-of-order loading |

---

## Recommended actions

1. **Fix BUG-1** immediately -- one-line change, file issue, ship as hotfix
2. **RISK-1** -- file issue, fix in next scheduled commit (Track F Commit 11)
3. **RISK-2** -- fix alongside RISK-1

---

## Process notes

- Track F shipped as 10 consecutive PRs (#1087-#1097) in one session with Commit 10 requiring 3 hotfix rounds
- The key mismatch (BUG-1) was introduced in Commit 5 (triage annotations, PR #1092) and survived Commits 6-10
- The triage annotation function was added without an integration test that specifically validates `$context['Findings']` post-triage
- Recommendation: add a targeted assertion in Test 32 that checks remediation/evidence sections are non-empty when triage data is present
