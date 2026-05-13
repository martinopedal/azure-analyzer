# Test Rigor Audit — False-Pass Pattern Scan

**Agent:** Sentinel  
**Date:** 2026-05-13  
**Scope:** Pester test suite scan for BUG-1 class (assertions that pass on null/empty/ghost data)

---

## Audit Methodology

**Pattern searched:** Tests using `Should -Match` / `Should -MatchExactly` without paired upstream non-null/non-empty assertions.

**Focus areas:**
1. `tests/integration/AuditorParity.Tests.ps1` (BUG-1 source)
2. `tests/orchestrator/InvokeAzureAnalyzer.Profile.Tests.ps1`
3. All `tests/integration/*.Tests.ps1` files
4. Renderer/report output tests

---

## Findings Summary

### 🔴 LIKELY-MASKING (High Risk)

#### F1: Test 32 — No upstream non-null assertion on findings
**File:** `tests/integration/AuditorParity.Tests.ps1:43`  
**Pattern:** `$htmlContent | Should -MatchExactly 'F-\d+-F-001'` without checking `$context['Findings']` is non-null before render.  
**Impact:** BUG-1 false-passed here. Regex matches even if findings table is empty (matches other page content or ghost rows).  
**Fix:** Add `$context['Findings'] | Should -Not -BeNullOrEmpty -Because 'triage must preserve findings'` before HTML assertions.

#### F2: Test 35a — CSV line count without null filter
**File:** `tests/integration/AuditorParity.Tests.ps1:212`  
**Pattern:** `$csvLines.Count | Should -BeGreaterThan 1` (header + at least 1 data row)  
**Impact:** If findings are null, CSV exports header only. `Count > 1` would catch it, but assertion is weak (should be `== 1601` for the fixture).  
**Fix:** Assert exact expected count: `$csvLines.Count | Should -Be 1601 -Because 'fixture has 1600 findings + 1 header'`.

#### F3: Test 32 — No assertion on empty table cells
**File:** `tests/integration/AuditorParity.Tests.ps1:43-46`  
**Pattern:** Asserts `<table` and `Severity` exist, but doesn't reject `<td></td>` ghost rows.  
**Impact:** If renderer iterates `@($null)`, produces `<td></td><td class=""></td><td></td><td></td>`. Test would pass.  
**Fix:** Add `$htmlContent | Should -Not -Match '<td></td>' -Because 'ghost null rows indicate broken data flow'`.

---

### 🟡 SUSPICIOUS (Medium Risk)

#### F4: Orchestrator profile test — Weak passthrough check
**File:** `tests/orchestrator/InvokeAzureAnalyzer.Profile.Tests.ps1:78`  
**Pattern:** `$result | Should -Not -BeNullOrEmpty` for `-PassThru` mode.  
**Impact:** PassThru returns a hashtable. If report FAILED but hashtable contains `SectionErrors`, test passes. Should check `$result.HtmlPath | Should -Exist`.  
**Fix:** Assert on actual output file existence, not just non-null return object.

#### F5: Pending test (Test 34b) blocks coverage
**File:** `tests/integration/AuditorParity.Tests.ps1:116`  
**Status:** `-Pending` (intentionally skipped for issue #1098)  
**Impact:** Tier 2 (EmbeddedSqlite) rendering is NOT tested. If Tier 2 has a similar null-findings bug, we won't catch it.  
**Recommendation:** Track as known gap; #1098 should include Tier 2 data-flow tests when implemented.

---

### 🟢 OK Patterns

#### OK1: Test 33 — Citation sanitization
**File:** `tests/integration/AuditorParity.Tests.ps1:83-89`  
**Pattern:** Tests credential scrubbing with explicit negative assertions (`Should -Not -MatchExactly 'P@ssw0rd123'`).  
**Verdict:** Correctly tests what it claims to test. No false-pass risk.

#### OK2: Test 38 — ValidateSet regression
**File:** `tests/integration/AuditorParity.Tests.ps1:254-270`  
**Pattern:** Tests parameter validation directly via `Get-Command` metadata introspection.  
**Verdict:** Robust. Cannot false-pass.

#### OK3: Test 37 — HTML encoding
**File:** `tests/integration/AuditorParity.Tests.ps1:248`  
**Pattern:** `Should -MatchExactly '&lt;script&gt;'` — asserts encoded output, AND rejects raw `<script>` tag.  
**Verdict:** Paired positive + negative assertion. Correct.

---

## Top 3 False-Pass Patterns (Prioritized)

1. **Regex match without upstream non-null/non-empty check** (F1, F3)  
   - Seen in: Test 32 (auditor parity), potentially across all renderer tests  
   - Root cause: PowerShell `@($null)` silently iterates once; `$null.Property` returns empty string, not error  
   - Fix template: Always pair `Should -Match` with `$data | Should -Not -BeNullOrEmpty` upstream

2. **Count assertions without exact expected value** (F2)  
   - Seen in: Test 35 (`Count > 1` instead of `Count == 1601`)  
   - Root cause: Weak inequality allows off-by-many bugs to slip through  
   - Fix template: Use exact counts when fixture size is known

3. **Result object checks without file-existence verification** (F4)  
   - Seen in: Orchestrator `-PassThru` tests  
   - Root cause: Function returns error-bearing object; non-null ≠ success  
   - Fix template: Assert on side effects (files created, counts populated) not just return non-null

---

## Test Statistics

**Total Pester baseline (from history.md):** 1369 passed / 0 failed / 5 skipped (1374 total)  
**Integration tests scanned:** 8 files under `tests/integration/`  
**Findings logged:** 5 (3 high-risk, 2 medium-risk)  
**Skipped tests:** 1 (`-Pending` for #1098)

---

## Recommendation

**Immediate action (Stream 3):**
1. Harden Test 32 with paired assertions (F1, F3)
2. Add new end-to-end test `AuditorDataFlow.Tests.ps1` asserting non-null at EVERY hand-off
3. Add hashtable-key safety helper `Assert-RequiredKey` to fail loud on missing keys

**Follow-up work (file as issues):**
1. Make Pester a required CI check (currently only `Analyze (actions)` is required)
2. Evaluate mutation testing (Stryker.NET / PSStryker) to catch weak assertions
3. Audit remaining test suites (normalizers, wrappers, shared modules)

---

**Next:** Stream 3 implementation on `squad/sentinel-test-rigor` branch.
