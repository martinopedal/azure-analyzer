# CI Permafix Audit Decision — 2026-04-23

**To:** Squad Coordinator (Copilot), Martin Opedal (Maintainer)  
**From:** Forge (Platform Automation & DevOps Engineer)  
**Re:** Banner-removal gate CI audit findings & permafix roadmap.

---

## Summary

Audit completed: 27 workflows inventoried, 7 root-cause investigations, 2 confirmed fixes (Pester pin #873, JSON sanitization #876), **1 critical P0 issue open** (watchdog dedup flood #877–#903, ~30 duplicate ci-failure issues today).

---

## Decision Required

**DO NOT remove banner** until watchdog P0 (exponential backoff + rollup pattern) is merged and verified in production for 48 hours.

**RECOMMEND:** Promote 5 advisory checks to required (Docs, Markdown, E2E, Closes-Link, Bicep) to enforce "green means green" contract.

---

## Permafix Roadmap

| Priority | Title | Effort | Impact | Owner |
|---|---|---|---|---|
| P0 | Watchdog dedup exponential backoff + rollup | 2 days | Eliminate CI-failure spam (30 dupe issues/day) | Copilot/Atlas |
| P1 | E2E + Release Pester retry wrap (belt & suspenders) | 1 day | Match ci.yml retry consistency | Any |
| P1 | Closes-link N/A override UX (error message clarification) | 1 day | Reduce false-positive friction | Any |
| P2 | CodeQL rate-limit cap review (docs) | 1 day | Clarify timeout behavior for maintainers | Any |
| P2 | Auto-approve documentation (allow-list + actor logic) | 1 day | Onboarding clarity | Any |

---

## Full Audit Report

**Location:** `.copilot/audits/forge-ci-audit-2026-04-23.md`

**Key findings:**
- ✅ All workflows SHA-pinned; retry wrapping present on external I/O.
- ✅ Secrets hygiene verified; no leaks detected.
- ✅ No infinite loop vectors (force-with-lease, dedup, token scoping correct).
- 🔴 **Watchdog dedup uses weak hash** (workflow+error_line capped to 120 chars → 12-char SHA) + no pre-create sweep = collision flood on rapid-fire failures.
- ⚠️ E2E + Release workflows missing Pester install retry wrap (low risk, consistency issue).

---

## Recommended Next Action

1. Open P0 permafix PR (watchdog dedup) targeting 48-hour merge.
2. Promote advisory checks to required in branch protection config.
3. Monitor ci-failure issue creation for 48 hours post-merge to confirm flood stops.

**If P0 PR encounters delays:** Post sticky issue to #604-debt tracking dupe-flood as a known limitation until exponential backoff lands.
