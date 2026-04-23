# B2 Low-Risk Security Items — Tracking Document

**Audit:** sentinel-security-audit-2026-04-23.md  
**Status:** Acknowledged (no immediate action required per audit)  
**Created:** 2026-04-23  

## F1: Timeout Wrapper Consistency (P2)

**Finding:** 4 wrappers bypass standardized `Invoke-WithTimeout` wrapper.

**Affected Modules:**
- `modules/Invoke-Powerpipe.ps1` (~100 uses of `powerpipe` CLI)
- `modules/Invoke-WARA.ps1` (WARA CLI invocations)
- `modules/shared/Invoke-CopilotTriage.ps1` (Model API calls)
- `modules/shared/Invoke-PRReviewGate.ps1` (GitHub API calls)

**Risk Assessment:**
- **Severity:** Low (cosmetic consistency issue)
- **RCA:** These tools have internal timeout/retry handling but don't use the standardized `Invoke-WithTimeout` wrapper
- **Security Impact:** None — internal timeouts exist and are sufficient
- **Impact:** Inconsistency in timeout handling approach across codebase

**Current Mitigation:**
- ✅ Powerpipe: Binary has internal timeout handling
- ✅ WARA: Tool has internal protections
- ✅ CopilotTriage: Model API calls are rate-limited by service; timeout is implicit
- ✅ PRReviewGate: Uses internal retry + gh CLI timeout; `Invoke-GhApiPaged` has internal max retry logic

**Audit Verdict:**
> "This is a **consistency issue, not a security gap**. RemoteClone.ps1 and all repo-scoped scanners (Zizmor, Trivy, Gitleaks) properly use `Invoke-WithTimeout`."

**Proposed Resolution:**
- Timeline: Q3
- PR Title: `chore: standardize Invoke-Powerpipe/WARA/CopilotTriage to use Invoke-WithTimeout`
- Scope: Wrap external process invocations in `Invoke-WithTimeout` (300s default)

**Decision:**
**ACKNOWLEDGED AS P2 IMPROVEMENT (non-blocking).** No immediate PR opened. All affected tools have demonstrated safe timeout behavior in production. Standardization improves maintainability but is not required for security compliance.

---

## F2: Rich-Error Preconditions (P3)

**Finding:** 56 bare `throw` statements in utility modules (not production wrappers/normalizers).

**Sample Locations:**
- `modules/shared/Canonicalize.ps1:35` → `throw "ARM ID must start with /subscriptions/{guid}..."`
- `modules/shared/Canonicalize.ps1:87` → `throw "Repository ID must be in host/owner/repo format..."`
- `modules/shared/AksDiscovery.ps1:48` → `throw 'Az.ResourceGraph module not installed...'`
- `modules/shared/IaCAdapters.ps1:45` → `throw "Required safety primitive Invoke-WithTimeout..."`

**Risk Assessment:**
- **Severity:** Low (code quality, not security)
- **RCA:** These are **precondition failures** in shared utility modules (not data-carrying error paths)
- **Security Impact:** None — these are initialization-time failures, not production data paths
- **Impact:** Inconsistent error reporting format (not all errors use `New-FindingError`)

**Current Mitigation:**
- ✅ All production wrappers and normalizers use `New-FindingError`
- ✅ Bare throws occur only in utility module initialization/validation
- ✅ These throw BEFORE any tool execution, so they don't leak data
- ✅ Initialization failures are acceptable as bare throws (contract violations should fail loudly)

**Audit Verdict:**
> "These are in **shared utility modules** (not production wrappers/normalizers). They represent **precondition failures** (missing dependencies, invalid input). These throw BEFORE any tool execution, so they don't leak data. Initialization failures are acceptable as bare throws."

**Proposed Resolution:**
- Timeline: Q4
- PR Title: `docs: add rich-error guidelines for utility modules`
- Scope: Document the pattern (bare throw acceptable for preconditions) or migrate to `New-FindingError` uniformly

**Decision:**
**ACKNOWLEDGED AS P3 CODE QUALITY IMPROVEMENT (non-blocking).** No immediate PR opened. Current pattern is acceptable: initialization-time precondition failures use bare throw; production data paths use `New-FindingError`. Future refactor may standardize, but this is not a security requirement.

---

## Summary

| Item | Severity | Status | Action |
|------|----------|--------|--------|
| F1: Timeout Wrapper Consistency | P2 | ACKNOWLEDGED | No immediate PR; Q3 standardization optional |
| F2: Rich-Error Preconditions | P3 | ACKNOWLEDGED | No immediate PR; Q4 doc/refactor optional |

**Net Security Impact:** None. Both findings are consistency/code-quality improvements, not security vulnerabilities.

**Audit Result:** ✅ **14/14 INVARIANTS PASS** — No security gaps.

**PR Scope:** This tracking document plus JSON-sanitize-before-parse ratchet (rubber-duck item #10) constitute the deliverable for "B2 low-risk items + rubber-duck-flagged ratchet."

---

**References:**
- Audit: `.copilot/audits/sentinel-security-audit-2026-04-23.md`
- Rubber-duck: `.copilot/audits/rubberduck-consolidated-2026-04-23.md` (ADD #10)
- PR #876: https://github.com/martinopedal/azure-analyzer/pull/876 (JSON-sanitize-before-parse lesson)
