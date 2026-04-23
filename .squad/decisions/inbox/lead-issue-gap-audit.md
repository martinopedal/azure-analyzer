# Lead Issue-vs-PR Gap Audit

**Date:** 2026-04-23  
**Auditor:** Lead (requested by Martin Opedal)  
**Context:** Post CI-stabilization push — multiple PRs merged in rapid succession

---

## Inventory Summary

| Category | Count |
|----------|-------|
| Open issues | 14 |
| Open PRs | 4 (PR #912, #914, #932, #944) |
| Recently merged PRs | 20 |
| Recently closed issues | 30 |

---

## Step 4: Open Issue Analysis

### Issue #946: fix: CI failure in Closes Link Required
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T20:12:07Z
- **Analysis:** Auto-generated ci-failure issue. The Closes Link Required workflow failed for a specific PR run (hash `ffe22eeaf1e5`). This is an advisory workflow — its failures are informational, not CI blockers. PR #947 (merged 20:31) added the advisory filter that prevents the watchdog from creating future issues for this workflow.
- **Resolution status:** ✅ **ALREADY RESOLVED** — PR #947 merged the advisory filter that now skips "Closes Link Required" failures. The underlying workflow itself is functioning correctly (it correctly flags PRs missing Closes links). This issue tracks a one-off watchdog-created alert for a transient event, not a systemic bug.
- **Suggested action:** Close with comment referencing PR #947.

---

### Issue #945: fix: CI failure in Docs Check (hash `8059618b25da`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T20:09:49Z
- **Analysis:** Auto-generated ci-failure issue for the Docs Check workflow. PR #941 (merged 20:04) fixed the docs-check workflow itself ("make docs-check workflow truly usable + clear stale CHANGELOG conflict markers"). PR #947 (merged 20:31) added the advisory filter preventing future watchdog issues for Docs Check.
- **Resolution status:** ✅ **ALREADY RESOLVED** — Root cause fixed by PR #941 (docs-check workflow). Recurrence prevented by PR #947 (advisory filter). This issue was created between the two merges.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #943: fix: CI failure in Docs Check (hash `1b19b11cc4f9`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T20:05:48Z
- **Analysis:** Same pattern as #945. Auto-generated before PR #941 merged at 20:04 (race — created 1 minute after merge but likely triggered by a run that started before the merge).
- **Resolution status:** ✅ **ALREADY RESOLVED** — Same as #945.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #942: fix: CI failure in Docs Check (hash `8429cd398ed7`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T20:03:58Z
- **Analysis:** Auto-generated ~1 minute before PR #941 merged. Same root cause (docs-check workflow was broken until #941 landed).
- **Resolution status:** ✅ **ALREADY RESOLVED** — Same as #945.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #939: fix: CI failure in Docs Check (hash `1544ae07e67d`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T19:50:16Z
- **Analysis:** Auto-generated before PR #941 merged. Docs Check was broken at the time.
- **Resolution status:** ✅ **ALREADY RESOLVED** — Same as #945.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #938: feat: replace dead auto-approve with proper gate solution
- **Labels:** squad, squad:forge, priority:p2
- **Created:** 2026-04-23T19:46:57Z
- **Analysis:** Filed after PR #937 removed the broken `auto-approve-bot-runs.yml`. Asks for a proper replacement for the first-time contributor approval gate that blocks bot PRs. Proposes (A) manual approval, (C) recognize Copilot as contributor, (D) document and accept. PR #944 (open) converts the watchdog from `workflow_run:` to `schedule:` trigger, which eliminates the cascade of stuck `action_required` runs — the main symptom. But #938 is broader: it asks for a complete gate solution.
- **Resolution status:** 🔨 **NEEDS NEW PR** (partially mitigated) — PR #944 mitigates the acute symptom (watchdog cascade) but doesn't implement the recommended (C)+(D) solution from the issue body. The first-time contributor gate may still fire on direct bot PR workflow runs, though its impact is now minimal since the cascade is broken. A scoped-down PR documenting the gate behavior in PERMISSIONS.md (option D) would satisfy the remaining acceptance criteria.
- **Gap risk:** Low — quality-of-life. The cascade was the real P1 problem and is fixed by PR #947's advisory filter + PR #944's schedule conversion. Residual gate approvals are rare manual clicks.
- **Suggested action:** Downgrade to P3, close with comment explaining the cascade is eliminated by PR #947 + #944, and residual gate behavior is acceptable per option (D). OR create a small docs PR adding gate behavior to PERMISSIONS.md.

---

### Issue #936: fix: CI failure in Docs Check (hash `52199f3f220c`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T19:43:56Z
- **Analysis:** Auto-generated before PR #941 merged. Same pattern as #933-#945.
- **Resolution status:** ✅ **ALREADY RESOLVED** — Same as #945.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #935: fix: CI failure in Docs Check (hash `9e5dce015f68`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T19:42:54Z
- **Analysis:** Same as #936.
- **Resolution status:** ✅ **ALREADY RESOLVED** — Same as #945.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #934: fix: CI failure in Docs Check (hash `8137ae8c4c33`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T19:36:50Z
- **Analysis:** Same as #936.
- **Resolution status:** ✅ **ALREADY RESOLVED** — Same as #945.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #933: fix: CI failure in Docs Check (hash `47911f3fdf6a`)
- **Labels:** squad, squad:forge, type:bug, priority:p1, ci-failure
- **Created:** 2026-04-23T19:35:52Z
- **Analysis:** Earliest of the Docs Check ci-failure batch. Created before PR #941 fixed the workflow.
- **Resolution status:** ✅ **ALREADY RESOLVED** — Same as #945.
- **Suggested action:** Close with comment referencing PR #941 + #947.

---

### Issue #926: feat: add -FixtureMode flag to enable E2E runs against tests/fixtures without Azure credentials
- **Labels:** enhancement, squad, squad:atlas, priority:p1
- **Created:** 2026-04-23T19:21:50Z
- **Analysis:** Requests a `-FixtureMode` switch on `Invoke-AzureAnalyzer.ps1` that runs normalizers directly against test fixtures without needing Azure credentials. This would enable contributor onboarding, CI validation, and demo runs. No existing PR addresses this. The acceptance criteria are well-defined: exit 0, integration test, README docs, 3+ tools producing findings.
- **Resolution status:** 🔨 **NEEDS NEW PR** — No PR exists. This is a substantial feature requiring changes to the orchestrator, normalizer loading, and test infrastructure.
- **Gap risk:** Medium — not a CI blocker, but a P1 feature that unblocks contributor experience and CI testing. Currently the only way to validate the tool is with live Azure credentials.
- **Suggested action:** Keep open. Assign to Atlas (already labeled squad:atlas). This is a next-sprint priority feature.

---

### Issue #910: fix(ci): allow trusted bots to bypass Closes/Fixes link requirement (B3)
- **Labels:** squad, squad:forge, type:bug, priority:p1
- **Created:** 2026-04-23T19:08:36Z
- **Analysis:** The Closes Link Required workflow blocks bot PRs (release-please, dependabot, etc.) that don't have `Closes #N` in their body. The fix is to add these bots to an author allow-list. PR #914 (open) implements this fix with `Closes #910` in its body.
- **Resolution status:** ✅ **WILL AUTO-CLOSE** — PR #914 has `Closes #910` and implements the exact fix described. **However**, PR #914 currently has **merge conflicts** (`mergeable: CONFLICTING`). It needs a rebase before it can merge.
- **Gap risk:** Medium — without this fix, release-please PRs (like the open PR #932) trigger the Closes Link Required check failure. This creates CI noise. The advisory filter in PR #947 prevents watchdog issues for these failures, but the workflow still shows as failed.
- **Suggested action:** Rebase PR #914, resolve conflicts, merge. This will auto-close #910.

---

### Issue #907: fix(wrappers): generalize non-null Findings + Errors envelope contract
- **Labels:** bug, squad, squad:atlas, squad:iris, priority:p1
- **Created:** 2026-04-23T19:06:21Z
- **Analysis:** Requests that all 37 wrappers emit a consistent v1 envelope (`Findings: @()`, `Errors: @()`, `SchemaVersion: '1.0'`) on every code path. Includes creating `New-WrapperEnvelope.ps1`, updating all wrappers, and adding per-wrapper envelope tests. PR #950 (merged) says "Closes #907 partially" — it fixed the `New-WrapperEnvelope.ps1` dot-sourcing issue (phantom object emission) but did NOT generalize the contract to all 37 wrappers.
- **Resolution status:** 🔨 **NEEDS NEW PR** — PR #950 fixed the foundation (`New-WrapperEnvelope.ps1` is now clean) but the full scope (update all 37 wrappers + ratchet tests + per-wrapper envelope tests) is unfinished. The issue body targets 37 additional tests; PR #950 delivered 0 of those.
- **Gap risk:** Medium — the envelope inconsistency causes downstream report failures (like #925, fixed by PR #927). The foundation is solid now, but individual wrappers can still emit null Findings/Errors on error paths.
- **Suggested action:** Keep open. This is a multi-wrapper sweep that could be split into smaller PRs per wrapper group.

---

### Issue #506: feat(impl): flesh out auditor-driven report builder (Track F / #434 / PR #481)
- **Labels:** enhancement, squad, squad:atlas, priority:p2, defer-post-window
- **Created:** 2026-04-22T21:58:57Z
- **Analysis:** Long-standing feature request for an auditor-driven report builder. Has the `defer-post-window` label indicating it was explicitly deferred beyond the current release window.
- **Resolution status:** ⏸️ **DEFERRED** — Explicitly deferred per plan. The `defer-post-window` label was intentionally applied. This is a post-preview-ship item.
- **Gap risk:** None for current sprint.
- **Suggested action:** Leave open. Re-evaluate after v1.2 ship window.

---

## Step 5: Cross-Check of Recently Closed Issues

### PR #947 batch closures (7 issues)
PR #947 ("watchdog skips advisory workflows") closed: #908, #913, #916, #920, #921, #923, #929.

| Issue | Type | Correct closure? |
|-------|------|-----------------|
| #908 | watchdog dedup race | ✅ Correct — advisory filter prevents the symptom |
| #913 | CI failure E2E | ✅ Correct — E2E is now advisory-filtered |
| #916 | CI failure Docs Check | ✅ Correct — Docs Check is advisory-filtered |
| #920 | CI failure Docs Check | ✅ Correct |
| #921 | CI failure E2E | ✅ Correct |
| #923 | CI failure E2E | ✅ Correct |
| #929 | CI failure E2E | ✅ Correct |

**Verdict:** All closures are valid. PR #947 eliminated the root cause (watchdog creating issues for advisory workflows).

### PR #927 closures
PR #927 ("MD report fails with .Compliant property error") closed #925 and #906.
- **#925** ("fix: Markdown report fails"): ✅ Correct — exact match.
- **#906** ("chore: regenerate samples"): ✅ Correct — PR #927 also regenerated samples.

### PR #931 closure
PR #931 ("add module import regression gate") closed #930.
- **#930** ("fix: add module import regression gate"): ✅ Correct — exact match.

### PR #922 closure
PR #922 ("sanitize-after-parse ratchet + B2 low-risk items") closed #915 and #911.
- **#915** ("fix(security): sanitize-after-parse"): ✅ Correct — exact match.
- **#911** ("fix(ci): add EOF to gh graphql transient retry"): ✅ Correct — B2 items included graphql retry patterns.

### PR #917 closure
PR #917 ("docs: coherence sweep") closed #909.
- **#909** ("docs: coherence sweep"): ✅ Correct — exact match.

### Earlier batch closures (#885-#903)
These 15+ ci-failure auto-issues were closed between 17:51-17:57, coinciding with merged PRs #871, #873, #874, #876. These were the first-wave Pester/CI failures resolved by pinning Pester 5.7.1 (#873), hardening PR Review Gate JSON parsing (#876), and improving graphql stderr handling (#871).

**Verdict:** All closures verified correct. No premature closures found.

### ci-failure issues that should have been closed by advisory filter but weren't
Issues #933, #934, #935, #936, #939, #942, #943, #945, #946 — all created BEFORE PR #947 merged at 20:31. The advisory filter prevents *new* issues but does not retroactively close existing ones. These 9 issues are the gap.

---

## Step 6: Gap Summary

### Issues closeable now but aren't (action: batch close)

| Issue | Reason | Action |
|-------|--------|--------|
| #933 | ci-failure Docs Check — fixed by PR #941 + filtered by PR #947 | Close |
| #934 | ci-failure Docs Check — same | Close |
| #935 | ci-failure Docs Check — same | Close |
| #936 | ci-failure Docs Check — same | Close |
| #939 | ci-failure Docs Check — same | Close |
| #942 | ci-failure Docs Check — same | Close |
| #943 | ci-failure Docs Check — same | Close |
| #945 | ci-failure Docs Check — same | Close |
| #946 | ci-failure Closes Link Required — filtered by PR #947 | Close |

### Issues that need PRs but have no agent assigned

| Issue | Type | Risk | Notes |
|-------|------|------|-------|
| #926 | Feature (FixtureMode) | Medium | Already assigned to squad:atlas. Needs implementation PR. |
| #907 | Bug fix (envelope contract) | Medium | Partially resolved by PR #950. Remaining scope: 37-wrapper sweep. |
| #938 | Feature (gate solution) | Low | Partially mitigated by PR #944+#947. Consider closing as "good enough." |

### Stale/superseded open PRs

| PR | Status | Recommendation |
|----|--------|----------------|
| #912 | Open, targets already-closed #908 | Close — superseded by PR #947's advisory filter. The coalesce-window approach is no longer needed since advisory workflows are filtered out. |
| #944 | Open, targets already-closed #908 | Close — the schedule-trigger conversion has independent value but its linked issue is resolved. The advisory filter (#947) eliminated the cascade problem without changing the trigger. If the schedule approach is still desired, re-file as a separate enhancement. |
| #914 | Open, merge conflicts | **Keep** — still needed for #910 (bot bypass). Needs rebase. |
| #932 | Open, release-please | **Keep** — will auto-merge after next release cycle. |

### Duplicates

No exact duplicates found among open issues. Issues #933-#936, #939, #942-#943, #945 are all distinct hashes of the same root cause (Docs Check failures) but are not duplicates of each other per watchdog design — each tracks a unique failure run. They're batch-closeable as a group.

### Systemic patterns

1. **Watchdog issue flood:** 9 of 14 open issues (64%) are ci-failure auto-issues that should have been caught by the advisory filter. The filter works for future runs but left a retroactive gap. **Recommendation:** After closing these 9, add a one-time sweep to the watchdog that closes stale ci-failure issues for advisory workflows.

2. **PR #914 merge conflict:** The Closes Link Required bot-bypass PR has gone stale. This is a recurring pattern where rapid main-branch merges leave agent PRs with conflicts. **Recommendation:** Prioritize rebase and merge of #914.

---

## Step 7: Batch Close Commands

### ci-failure auto-issues (advisory workflows — resolved by PR #941 + #947)

```bash
# Docs Check failures — root cause fixed by PR #941, recurrence prevented by PR #947
gh issue close 933 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."
gh issue close 934 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."
gh issue close 935 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."
gh issue close 936 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."
gh issue close 939 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."
gh issue close 942 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."
gh issue close 943 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."
gh issue close 945 --comment "Resolved: Docs Check workflow fixed by PR #941; advisory filter (PR #947) prevents future watchdog issues for this workflow."

# Closes Link Required failure — advisory-filtered by PR #947
gh issue close 946 --comment "Resolved: Closes Link Required is now advisory-filtered by PR #947. This one-off failure does not indicate a systemic bug."
```

### Stale PRs (superseded by merged fixes)

```bash
gh pr close 912 --comment "Superseded: Issue #908 resolved by PR #947 (advisory filter). The 24h coalesce window is no longer needed." --delete-branch
gh pr close 944 --comment "Superseded: Issue #908 resolved by PR #947 (advisory filter). The cascade problem is eliminated. If schedule-trigger conversion is still desired, re-file as a separate enhancement." --delete-branch
```

---

## Remaining Open Items After Batch Close

| Issue | Priority | Owner | Status |
|-------|----------|-------|--------|
| #910 | P1 | squad:forge | Blocked on PR #914 rebase |
| #907 | P1 | squad:atlas + squad:iris | Needs 37-wrapper sweep PR |
| #926 | P1 | squad:atlas | Needs implementation PR |
| #938 | P2 | squad:forge | Consider closing as mitigated |
| #506 | P2 | squad:atlas | Deferred (defer-post-window) |

**Net open after batch close: 5 issues (down from 14)**
