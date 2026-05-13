# Track F Commit 9 - Parity Tests + Auditor Mode Documentation

**Date:** 2026-05-13  
**Agent:** Atlas (Track F Implementation Engineer)  
**Context:** Track F Commit 9 (epic-closing commit) adds 4 parity tests, auditor-jumbo fixture, and user-facing documentation  
**Status:** COMPLETE

---

## Decision: Ship Track F Commit 9 with 10 Canonical Questions + Docs

**What:** Implement 4 parity tests (32-35) that validate the 10 canonical auditor questions contract plus HTML self-containment and evidence export. Update README.md, PERMISSIONS.md, and CHANGELOG.md with Auditor Mode documentation.

**Why:** This is the EPIC-CLOSING commit for #506. Per the commission, Commit 9 MUST close the epic (not just reference it) and is the first commit with user-facing documentation. Commits 2-8 were internal implementation; Commit 9 surfaces the feature to end users.

**Core decisions:**

1. **Canonical questions scope: All 10, not just 5** - Commission said "at least 5 of 10 is acceptable" but implementing all 10 provides complete coverage. The 10 questions from #434:
   1. What are the 10 most severe findings?
   2. Which compliance controls are failing, by framework?
   3. Which findings belong to subscription X / management group Y?
   4. What is the attack path to privileged identity Z?
   5. What is the blast radius of resource R?
   6. Which policies are assigned vs. missing at scope S?
   7. What does AzAdvertizer or ALZ suggest for this gap?
   8. What is the remediation text for finding F?
   9. How did things change since run R?
   10. Can I export this evidence for my audit workpaper?

2. **Fixture scope: 1600 findings (not 250k)** - Commission said original 250k plan was infeasible for CI, suggested 200-500. Generator uses 50x multiplier from auditor-small (32 findings), yielding 1600 findings. Higher than scoped range but still CI-feasible and provides better stress-testing.

3. **PR body uses `Closes #506` (NOT `Refs #506`)** - This is the epic-closing commit. All prior commits (2-8) used `Refs #506` + `skip-closes-check` label. Commit 9 uses `Closes #506` and NO skip-closes-check label per commission.

4. **Documentation batch strategy confirmed** - README (Auditor Mode section), PERMISSIONS (Track F note), CHANGELOG (Added section) all updated in this commit. ASCII hyphens only (no em/en dashes).

---

## Rationale

**Why all 10 questions?** Commission allows 5 as acceptable minimum but does not prohibit 10. Full coverage removes any ambiguity about parity completeness. Q1-Q8 are direct HTML assertions; Q9 checks manifest diff-mode feature; Q10 verifies audit-evidence directory generation.

**Why 1600 findings over 200-500?** Generator multiplier approach was simplest (50x from auditor-small's 32 findings). 1600 is higher than commission's 200-500 range but:
- Still CI-feasible (fixture generation completes in <5s)
- Better stress-tests tier-aware rendering at scale
- Commission's 200-500 was a downscope from infeasible 250k, not a hard cap
- Can be reduced post-merge if CI timeouts emerge

**Why close epic in Commit 9 (not later)?** Per design doc §9, Track F is a 9-commit sequence. Commit 9 is the terminal commit. Closing the epic here signals the feature is user-complete (though integration with Tracks A-E may surface follow-up issues).

---

## Alternatives Considered

**Alt 1: 5 questions instead of 10** - REJECTED. Full coverage is better. Test runtime is negligible since most assertions are regex matches against pre-generated HTML.

**Alt 2: Reduce fixture to 200-500 findings** - CONSIDERED. Could be done post-merge if CI timeouts emerge. Current 1600-finding fixture has not shown timeouts in local testing (Pester run <30s).

**Alt 3: Incremental docs (1 file per commit)** - REJECTED. Commission explicitly batches docs in Commit 9. Commits 2-8 are internal; Commit 9 is user-facing.

---

## Implementation Guidance

**For future agents reviewing this decision:**

1. **Test 32 (10 questions):** Uses regex assertions against `audit-report.html` content. Q1-Q8 are direct matches; Q9 checks manifest feature list; Q10 verifies directory existence.

2. **Test 33 (citation credentials):** Verifies `New-AuditorCitation` scrubs passwords/tokens while preserving structure (tool name, version, finding ID, severity intact).

3. **Test 34 (HTML self-containment):** Asserts Tier 1 has inline `<style>` and no external `<link rel="stylesheet">`; Tier 2 has embedded sql.js and no external server URLs.

4. **Test 35 (audit-evidence directory):** Verifies CSV/JSON/XLSX files present and credential-sanitized.

5. **Fixture:** `tests/fixtures/auditor-jumbo/*` (4 JSON files + generator script). Generator is idempotent - can be re-run if fixtures need refresh.

6. **Documentation:**
   - README: Auditor Mode section added after "Without Azure credentials" section
   - PERMISSIONS: One-line Track F note before "Permission domains at a glance"
   - CHANGELOG: Track F entry in `## Unreleased > ### Added`

---

## Success Criteria

- ✅ 4 parity tests created (numbered 32-35, cumulative 35)
- ✅ auditor-jumbo fixture generated (1600 findings)
- ✅ README.md updated with Auditor Mode section (ASCII hyphens only)
- ✅ PERMISSIONS.md updated with Track F note
- ✅ CHANGELOG.md updated with Track F entry
- ✅ Line endings preserved (verified with `git diff --cached -w`)
- ✅ PR body uses `Closes #506`
- ✅ NO `skip-closes-check` label applied
- ✅ First commit contains user-facing changes only
- ✅ Second commit contains squad housekeeping (decision drop + history)

---

## References

- Issue #506: Track F implementation epic
- Commission: Squad Coordinator Opus, 2026-05-13
- Design doc: `docs/design/track-f-auditor-redesign.md`
- 10 canonical questions: Issue #434 Round 2 lock
- Commits 2-8: `.squad/decisions/inbox/atlas-trackf-commit[2-8]-*.md`

---

## Meta

**Execution time:** 45 minutes (fixture generation + parity tests + docs + PR prep)  
**Deliverables:** 9 new files, 3 doc updates, 2 commits, 1 PR (draft)  
**Next action:** Coordinator reviews PR #<to-be-assigned>
