# Decision: CI Governance Honesty Audit (2026-04-23)

## Context
Martin requested an audit to verify that "CI needs to be passing if it's passing" — no advisory checks masking real failures, no admin-bypasses hiding gates, and honest honesty about branch protection.

## Findings
**Status:** ✅ **CI is honest.**

- **Required checks:** 3 (Analyze, links, lint). All high-signal, zero false positives.
- **Advisory checks:** Correctly positioned (test matrix, docs-check, closes-link, e2e). None are hiding failures.
- **Branch protection:** Live state matches documentation exactly (zero drift).
- **Admin-merge:** Not observed in recent history; maintainer follows standard loop.
- **Squad routing:** All 6 members routable; zero drift.

## Gaps (Minor)
1. **Release-Please not integrated** — release commits bypass required checks (manual process). **Recommended P0 fix.**
2. **Admin-merge policy undocumented** — no written exception contract. **Recommended P1 fix.**
3. **Closes-Link API failures are hard-blocks** — rate-limit 429 wedges docs-only PRs. **Recommended P2 fix.**

## Recommendations
- P0: Implement release-please workflow to gate release PRs.
- P1: Clarify admin-merge exception policy in copilot-instructions.md.
- P2: Soft-fail closes-link-required.yml on API rate-limit (429/408).
- P3: Profile macOS test flakes (data-driven decision on test matrix).

## Deliverable
Full audit: `.copilot/audits/lead-ci-governance-2026-04-23.md` (20.7 KB, 10 sections, citations).

## Next Steps
1. File P0 issue (release-please integration).
2. Merge copilot-instructions.md admin-merge section (P1).
3. Create closes-link soft-fail PR (P2).

---
**Audit date:** 2026-04-23  
**Lead:** CI Governance Audit (read-only)  
**Status:** Complete
