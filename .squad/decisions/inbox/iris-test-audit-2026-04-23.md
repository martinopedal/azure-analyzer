# iris-test-audit-2026-04-23 — Decision Inbox

**Date:** 2026-04-23  
**Auditor:** Iris (Entra ID & Microsoft Graph Engineer)  
**Status:** READY FOR SQUAD TRIAGE

---

## VERDICT
✓ **Ratchet Baseline MAINTAINED** — 842-test minimum verified. Current: ~2,190 `It` blocks.

⚠️ **3 High-Priority Gaps Detected:**
1. **P1:** `Invoke-IdentityCorrelator.Tests.ps1` (core Entra wrapper untested)
2. **P1:** `Invoke-PRAdvisoryGate.Tests.ps1` (critical PR gate untested)
3. **P1:** `RubberDuckChain.Tests.ps1` (error recovery loop untested)

---

## KEY FINDINGS

| Category | Result | Action |
|----------|--------|--------|
| Wrapper coverage | 94.6% (35/37) | File P1 tickets for missing 2 wrappers |
| Normalizer coverage | 100% (36/36) | ✓ No action |
| Shared module coverage | 75% (30/40) | P2: file tickets for 10 utilities |
| Entra/Graph coverage | 75% (3/4 critical) | P1: add tests for IdentityCorrelator wrapper |
| CON-003 ratchet | ✓ All 37 wrappers pass | ✓ No action |
| Test isolation | ✓ Guard passes | ✓ No action |
| Skipped tests | 7 conditional, 0 `-Pending` | P2: uncomment AttackPath tests when #432b lands |

---

## PROPOSED PR TITLES (Priority Order)

### P1 (Before next merge)
1. `test: add unit tests for Invoke-IdentityCorrelator wrapper` — scope: `modules\Invoke-IdentityCorrelator.ps1`.
2. `test: add unit tests for Invoke-PRAdvisoryGate shared module` — scope: `modules\shared\Invoke-PRAdvisoryGate.ps1`.
3. `test: add unit tests for RubberDuckChain retry orchestrator` — scope: `modules\shared\RubberDuckChain.ps1`.

### P2 (Q2 backlog)
4. `test: add unit tests for Invoke-CopilotTriage wrapper` (optional AI feature).
5. `test: add unit tests for AuditorReportBuilder` (report utility).
6. `test: add unit tests for ExecDashboardRender` (dashboard utility).
7. `test: add unit tests for KqlQuery` (query helper).
8. `test: add unit tests for KubeAuth` (Kubernetes auth).
9. `test: add unit tests for MissingToolTestHarness` (helper).
10. `test: add unit tests for RateLimit` (throttle logic).
11. `test: add unit tests for Viewer` (formatter).
12. `test: enable AttackPath deferred-field tests` (depends on #432b).

---

## CITATIONS (Full Audit Report)
See: `.copilot\audits\iris-test-audit-2026-04-23.md` (sections 1–10).

---

## SQUAD SIGN-OFF
**Ready for:** Ralph (Squad Coordinator) → Assign P1 tickets to next sprint.  
**Hold until:** All P1 findings addressed in a PR + green CI.
