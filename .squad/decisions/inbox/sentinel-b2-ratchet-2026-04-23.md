# Sentinel: B2 Low-Risk Items + JSON Sanitize-After-Parse Ratchet

**Date:** 2026-04-23  
**Agent:** Sentinel  
**Issue:** #915  
**PR:** #922  

## Decision

Land B2 low-risk security audit items (documented as acknowledged non-blocking improvements) plus JSON-sanitize-after-parse ratchet test generalizing PR #876 lesson.

## Context

### B2 Security Audit

Sentinel completed comprehensive security audit (`.copilot/audits/sentinel-security-audit-2026-04-23.md`):
- **Audit Scope:** 14 security invariants from `.copilot/copilot-instructions.md`
- **Result:** ✅ 14/14 PASS
- **Findings:** 2 low-risk items (P2/P3), both acknowledged as non-blocking

### Rubber-Duck ADD #10

Rubber-duck consolidated audit identified missing ratchet to prevent JSON-sanitize-before-parse anti-pattern regression (`.copilot/audits/rubberduck-consolidated-2026-04-23.md`):
> "Sentinel ratchet for JSON-sanitize-before-parse (PR #876 lesson not generalized; `Invoke-PRReviewGate.ps1:131-136` still does pre-parse sanitize)"

Note: The comment at L131-136 is actually **correct** (documents the lesson), but the ratchet to prevent future regressions elsewhere was missing.

## Implementation

### 1. JSON Sanitize-After-Parse Ratchet ✅

**File:** `tests/shared/JsonSanitizeOrderRatchet.Tests.ps1`

**Purpose:** Prevent future instances where `Remove-Credentials` is called on raw JSON text before `ConvertFrom-Json`, which corrupts JSON when credential-like patterns exist in string values (e.g., `"password": "foo"` in diff_hunk fields).

**Detection Logic:**
- Scans all `modules/**/*.ps1` files
- Identifies pattern: `$sanitized = ... | Remove-Credentials` followed by `$sanitized | ConvertFrom-Json`
- Skips safe patterns (Remove-Credentials in error paths only)

**Baseline:** 0 violations (all current usage is safe)

**Reference:** PR #876 fixed this in `Invoke-PRReviewGate.ps1`

### 2. B2 Low-Risk Items Tracking Document ✅

**File:** `.copilot/audits/b2-low-risk-items-tracking.md`

**F1 (P2): Timeout Wrapper Consistency**
- **Finding:** 4 wrappers bypass standardized `Invoke-WithTimeout` wrapper
- **Affected:** Invoke-Powerpipe, Invoke-WARA, Invoke-CopilotTriage, Invoke-PRReviewGate
- **Risk:** Low (cosmetic consistency issue)
- **Mitigation:** All tools have internal timeout/retry handling
- **Decision:** ACKNOWLEDGED AS P2 IMPROVEMENT (non-blocking)

**F2 (P3): Rich-Error Preconditions**
- **Finding:** 56 bare `throw` statements in utility modules
- **Risk:** Low (code quality, not security)
- **Mitigation:** These are initialization-time precondition failures (not data paths)
- **Decision:** ACKNOWLEDGED AS P3 CODE QUALITY IMPROVEMENT (non-blocking)

### 3. CHANGELOG Entry ✅

Added to "Added" section:
- Security ratchet: `tests/shared/JsonSanitizeOrderRatchet.Tests.ps1`
- B2 audit tracking: `.copilot/audits/b2-low-risk-items-tracking.md`

## Rationale

### Why Document vs. Fix?

**B2 Items:** Both findings are **consistency/code-quality improvements, NOT security vulnerabilities**:
- F1: Internal timeouts exist and work correctly in production
- F2: Bare throws are acceptable for precondition failures (initialization-time, not data paths)

**Audit Verdict:** "This is a **consistency issue, not a security gap**."

### Why Add Ratchet?

PR #876 fixed the specific instance in `Invoke-PRReviewGate.ps1`, but the lesson was not generalized. Without a ratchet, future PRs could reintroduce the anti-pattern in other modules.

**Pattern:**
```powershell
# WRONG (corrupts JSON):
$sanitized = $rawJson | Remove-Credentials
$obj = $sanitized | ConvertFrom-Json  # ❌

# CORRECT (parse first, sanitize after):
$obj = $rawJson | ConvertFrom-Json
$sanitizedJson = $obj | ConvertTo-Json | Remove-Credentials
Set-Content output.json $sanitizedJson  # ✅
```

## Testing

✅ All 3 tests pass:
- Ratchet baseline (0 violations)
- Safe pattern allowance (error path usage)
- Synthetic anti-pattern detection

## Outcome

- **Issue #915:** Closes
- **PR #922:** Awaiting review
- **Branch:** `fix/security-ratchet-20260423`
- **Status:** Ready to merge

## References

- B2 audit: `.copilot/audits/sentinel-security-audit-2026-04-23.md`
- Rubber-duck: `.copilot/audits/rubberduck-consolidated-2026-04-23.md`
- PR #876: https://github.com/martinopedal/azure-analyzer/pull/876
- PR #922: https://github.com/martinopedal/azure-analyzer/pull/922
