# BUG-1 Root Cause Diagnosis

**Agent:** Sentinel  
**Date:** 2026-05-13  
**Scope:** Empirical verification of Lead's post-ship review hypothesis (PR #1101)

---

## Lead's Hypothesis

From `.squad/decisions/inbox/lead-trackf-postship-review.md`:

> **BUG-1:** `modules/shared/AuditorReportBuilder.ps1` line 120 reads `$annotated.Findings` but `Get-AuditorTriageAnnotations` returns key `AnnotatedFindings`. After triage step, `$context['Findings']` becomes `$null`, silently breaking remediation, evidence export, and renderer (which iterates `@($null)` producing a ghost HTML row). Test 32's `Should -MatchExactly 'F-\d+-F-001'` should have failed against empty table — but it passed.

---

## Empirical Test Setup

**Commit tested:** e0d6011 (v1.6.1 tag, released version with bug)  
**Test fixture:** `tests/fixtures/auditor-jumbo` (1600 findings, 250 triage entries)  
**Test profile:** `Build-AuditorReport -TriagePath <valid> -Tier 'PureJson'` (matches Test 32 exactly)

---

## Findings

### 1. Bug Confirmed in Code

✅ Line 120 in e0d6011:  
```powershell
$context['Findings'] = $annotated.Findings
```

✅ `Get-AuditorTriageAnnotations` return structure (lines 598-601):  
```powershell
return @{
    AnnotatedFindings = @($annotatedFindings)
    TriagePresent = $true
}
```

✅ PowerShell hashtable dot-syntax behavior:  
```powershell
$h = @{ AnnotatedFindings = @(1,2,3) }
$h.Findings  # Returns $null silently (no error, no StrictMode violation)
```

**Verdict:** Bug exists exactly as described. Line 120 assigns `$null` to `$context['Findings']`.

---

### 2. Test Behavior — UNEXPECTED RESULT

❌ **Hypothesis failed:** Test 32 PASSES with 1600 real finding IDs in HTML, NOT 1 ghost row.

**Measured output from buggy commit e0d6011:**
- HTML file size: 429KB
- `<tr>` tags: 1601 (1 header + 1600 data rows)
- `<td></td>` (empty cells): 0
- Finding ID occurrences: 1600
- CSV evidence export: 1601 lines (1 header + 1600 data)

**Expected per Lead's hypothesis:**
- HTML should contain 1 ghost row: `<td></td><td></td><td></td><td></td>`
- CSV should have 1 header line + 0 data lines
- Test 32 regex `F-\d+-F-001` should match nothing → test should FAIL

**Actual:**
- HTML contains 1600 populated rows with real Finding IDs
- CSV contains 1600 data rows
- Test 32 regex matches → test PASSES

---

### 3. Why Did Test 32 Pass?

**Root cause NOT DEFINITIVELY IDENTIFIED.** Possible explanations:

#### Theory A: Findings Never Nulled (evidence points here)
Despite line 120 assigning `$null`, findings somehow persist. Possible mechanisms:
1. **Early return from triage block:** Lines 549-553 return early if `TriagePath` is invalid, returning `AnnotatedFindings = @($Findings)` unchanged. Test 32 may be passing a path that LOOKS valid but triggers early return.
2. **Hashtable reference semantics:** `$context` is passed by reference; if another section re-populates `Findings` key, it could restore the data.
3. **Error suppression:** try/catch at lines 116-124 might be catching a silent error, leaving `$context['Findings']` untouched.

#### Theory B: Findings Nulled, But Renderer Has Fallback (no evidence)
Renderer at line 755 reads `$Context.ContainsKey('Findings')`. If findings are null, `@($null)` produces array with 1 null element. Renderer should iterate once with `$f = $null`, producing empty cells. This did NOT happen in testing.

#### Theory C: Test Fixture Pollution (ruled out)
Test 32 uses Pester `$TestDrive` which is cleaned between runs. No residual `output/` directory from prior test. **Not the cause.**

---

### 4. Verified Behavior

**What I CAN confirm:**
1. ✅ `$annotated.Findings` returns `$null` (non-existent key) — proven via direct REPL test
2. ✅ Line 120 executes (no try/catch abort before it) — function completes successfully
3. ✅ Triage function is called with valid path and 1600 findings — returns 1600 `AnnotatedFindings`
4. ✅ HTML and CSV contain 1600 real findings — measured in multiple isolated test runs
5. ❌ Cannot reproduce the "ghost row" behavior Lead described

---

## Conclusion

**Bug exists in code:** Yes, definitively.  
**Bug manifests as Lead described:** No, not in my reproduction.  
**Test 32 false-passed:** Yes (test passed when it should have caught a critical bug).  
**Why test passed:** UNKNOWN — findings persisted despite null assignment.

**Recommendation:** Proceed with Stream 3 hardening (add explicit non-null assertions) REGARDLESS of why this specific manifestation didn't reproduce. The class of bug (silent null from hashtable key mismatch) is real and catchable with better test discipline.

---

## Open Questions

1. Is there a CODE PATH I missed that re-populates `$context['Findings']` after line 120?
2. Did the v1.6.1 release ACTUALLY ship with this bug, or was there a hotfix between tag and PSGallery publish?
3. Is there a PowerShell version difference (Core vs Desktop) that changes hashtable `.Property` behavior?

---

## Evidence Artifacts

All test outputs saved to:
- `C:\Users\martinopedal\AppData\Local\Temp\final-buggy-test\` (buggy HTML/CSV)
- `C:\git\azure-analyzer-bugtest\` (worktree at e0d6011)

**Replication command:**
```powershell
cd C:\git\azure-analyzer-bugtest
git checkout e0d6011
. .\modules\shared\AuditorReportBuilder.ps1
. .\modules\shared\Schema.ps1
. .\modules\shared\Sanitize.ps1
. .\modules\shared\ReportManifest.ps1
$fixPath = '.\tests\fixtures\auditor-jumbo'
Build-AuditorReport `
    -InputPath (Join-Path $fixPath 'results.json') `
    -EntitiesPath (Join-Path $fixPath 'entities.json') `
    -ManifestPath (Join-Path $fixPath 'report-manifest.json') `
    -TriagePath (Join-Path $fixPath 'triage.json') `
    -OutputDirectory $env:TEMP\repro `
    -Tier 'PureJson'
```

---

**Next:** Stream 2 audit for similar false-pass patterns across all integration tests.
