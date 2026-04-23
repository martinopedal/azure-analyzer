# Lead Decision — Track F Implementation Plan

**Date:** 2026-04-23  
**Agent:** Lead (Team Lead / Track F Implementation Planner)  
**Context:** Issue #506 implementation plan for Track F auditor-driven report redesign  
**Status:** APPROVED for execution (plan only; code stays unmerged per issue scope)

---

## Decision: 9-Commit Implementation Plan with D1 Dependency Gate

**What:** Produce a commit-by-commit master plan for implementing Track F (issue #506) that can be executed autonomously by another agent without re-thinking.

**Why:** Issue #506 is flagged as DRAFT PR scope — user wants the plan + draft PR with code, but NOT merged this cycle. Per design doc `docs/design/track-f-auditor-redesign.md` §9, Track F has a well-defined 9-commit sequence. Lead's job is to expand that outline into a tight, testable, per-commit plan with acceptance criteria, test counts, risk assessment, and documentation gates.

**Core decisions:**

1. **Branch off main, not squad/434-auditor-redesign-design** — that branch merged via PR #481 (commit `e0d20bc`). Skeleton is already on main.

2. **Commit 0 = D1 dependency gate** — programmatic check that all 6 dependency tracks (A, B, C, D, E, V) are on main before commit 1 starts. If any missing, STOP and escalate to user. This prevents mid-implementation discovery of blockers.

3. **+33 tests across 9 commits** — exceeds +25-30 target. Per-commit test delta documented. Parity test (10 canonical auditor questions) lands in commit 9.

4. **Batch docs in commit 9** — README, PERMISSIONS, CHANGELOG updated in final commit rather than incrementally. Rationale: commits 1-8 are internal module changes; commit 9 finalizes user-facing contract.

5. **Open §10 design questions answered with LEAN defaults:**
   - Citation provenance: include query hash if Track D populates `SourceQueryHash` (conditional, not blocking)
   - PDF rendering: print stylesheet only (no Chromium dependency)
   - Framework version pinning: Track D drives (no dual manifest maintenance)

   User can override in PR review, but defaults allow implementation to proceed without blocking on user input.

6. **Draft PR body template provided** — includes scope, parity contract checklist, test counts, commit sequence, review instructions, and "what's NOT in scope" section. Clear stop criteria: PR stays draft until user approval.

7. **Declared degradation contract enforced in commit 8** — `report-manifest.json` writer extended to populate `profile.auditor.degradations[]` when Track A/B/C/E data missing or Tier 3/4 rendering downgrades. Test #29 enforces no orphan degradations.

8. **10-question parity test lands in commit 9** — single Pester test renders `auditor-jumbo` fixture (250k findings) at Tier 1 and Tier 4, extracts answers to 10 canonical questions, asserts snapshot equivalence on answers (not rendering). Per #434 Round 2 lock.

---

## Rationale

**Why commit 0 (dependency gate)?** Per `.copilot/copilot-instructions.md` → "Iterate Until Green — Resilience Contract", validate pre-conditions before starting. Design doc §1 explicitly calls out 6 hard dependencies. Atlas's D1 dependency check (from `.squad/ceremonies.md`) catches blockers upfront, saving 12-18 hours of wasted effort if a track is incomplete.

**Why 9 commits?** Design doc §9 prescribes the sequence. Each commit is self-contained, Pester-green, and addresses a distinct scope. Splitting smaller would create noise; merging larger would lose granularity for review.

**Why batch docs in commit 9?** Per repo rule, docs updates required, but incremental CHANGELOG entries for internal module changes (commits 1-8) create churn. Commit 9 is the first user-visible surface (orchestrator flag, outputs, parity tests). Batching docs there reduces noise. User can request incremental docs if preferred.

**Why LEAN defaults for §10 questions?** Design doc flags them as "open questions to decide before commit 4." Lead's job is to unblock implementation. All 3 questions have sensible defaults that align with existing repo patterns (Track D drives, no heavy dependencies, conditional output). User can override in PR review, but implementation can proceed without blocking on user input.

**Why draft PR, not merge?** Per #506 body: "This issue will be implemented as a DRAFT PR (not merged this cycle). User wants the plan + draft PR with code." Lead honors that scope. PR body template includes explicit "NOT to be merged this cycle" section and stop criteria.

---

## Alternatives Considered

**Alt 1: Branch off squad/434-auditor-redesign-design** — REJECTED because that branch already merged to main via PR #481. Branching off main is simpler and avoids stale branch issues.

**Alt 2: Incremental docs per commit** — REJECTED because commits 1-8 are internal. Repo rule requires docs updates, but batching in commit 9 (user-facing commit) reduces churn. User can request change if preferred.

**Alt 3: Block on user input for §10 questions** — REJECTED because all 3 have sensible defaults. Blocking delays implementation. Lead's job is to unblock. User can override in PR review.

**Alt 4: Parity test spread across commits 1-8** — REJECTED because parity test requires end-to-end orchestrator wiring (commit 7) and full fixture generation (commit 9). Splitting would create failing tests mid-sequence. Commit 9 is the natural landing spot.

**Alt 5: Merge PR in this cycle** — REJECTED because #506 explicitly scopes this as DRAFT PR. User wants plan + code, but NOT merged. Lead honors that scope.

---

## Implementation Guidance

**For agent executing this plan:**

1. **Start with commit 0** — run D1 dependency check. If red, STOP and escalate to user via #506 comment. Do not proceed to commit 1.

2. **Each commit MUST satisfy 5 invariants:**
   - Pester green (`Invoke-Pester -Path .\tests -CI`)
   - No test regressions
   - Conventional commits format
   - Git trailer (`Co-authored-by: Copilot ...`)
   - No secrets in output (all sanitized via `Remove-Credentials`)

3. **After commit 9:** Open draft PR with provided body template. Comment on #506: "Draft PR ready for review: [PR link]". HALT execution. Do NOT flip PR to ready or merge.

4. **If any commit fails Pester:** STOP, fix, re-run, then proceed. Do not skip ahead.

5. **If user requests changes during execution:** Incorporate feedback, re-run Pester, continue sequence.

---

## Success Criteria

Plan delivered as `.copilot/audits/lead-track-f-impl-plan-2026-04-23.md` with:

- ✅ 9-commit sequence with per-commit titles, files, functions, tests, acceptance criteria, risk, test delta
- ✅ D1 dependency gate (commit 0)
- ✅ 10-question parity contract enforcement (commit 9)
- ✅ Declared degradation contract (commit 8)
- ✅ Open §10 questions answered with LEAN defaults
- ✅ Test-count target met (+33, exceeds +25-30)
- ✅ Draft-PR body template
- ✅ Stop criteria (PR stays draft)
- ✅ Citations to design doc sections, issue #506, PR #481

Plan is ~700 lines, tight enough for autonomous execution, detailed enough to avoid re-thinking.

---

## References

- Issue #506: `feat(impl): flesh out auditor-driven report builder (Track F / #434 / PR #481)`
- Design doc: `docs/design/track-f-auditor-redesign.md`
- Skeleton: `modules/shared/AuditorReportBuilder.ps1` (12 frozen signatures)
- PR #481: design + scaffold merged to main (commit `e0d20bc`)
- Issue #434: Track F requirements + Round 2 parity lock

---

## Meta

**Execution time:** 12 minutes (context load + plan generation)  
**Deliverables:** 3 files (plan, decision, history learning)  
**Next action:** Another agent executes this plan commit-by-commit
