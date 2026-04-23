# Rubber-duck consolidated critique — 2026-04-23

> The rubber-duck reviewed all 8 audit deliverables against the user's hard directives (no temp fixes, CI honesty, docs coherent, banner-down gate). Verdict: **⚠️ Land with adjustments**. Several audit recommendations are stale, factually wrong, or symptom-patches.

## TL;DR — what to drop, fix, and add

### DROP these recommendations
- **Lead-A2 P0** "Add release-please workflow" — `release.yml` already integrates release-please. Don't open this PR.
- **Sage P1** "`-AlzReferenceMode` undocumented" — already documented in `Invoke-AzureAnalyzer.ps1:58-66` + `docs/design/policy-enforcement.md:113-119`. False positive.
- **Sage** "Banner ready now" — violates user gate. Banner stays up until ALL Phase G criteria met.
- **Lead-A2 P2** "Soft-fail closes-link on 429/408" — silently passes work that may be unlinked. Violates honesty.

### FIX these (root-cause, not symptom)
- **Lead-A2 honesty rationale is broken**: `Analyze (actions)` = **CodeQL**, NOT the Pester test matrix. So "keep Test matrix advisory because Analyze catches it" is false. Need to recompute required-check policy from actual workflows, not status-check names.
- **Closes-link API retry**: real fix is reliable enumeration + explicit override semantics, not message-text tweaks or soft-fail.
- **Track F D1↔D2 contradiction on remediation appendix grouping**: D1 says group by `Finding.Title` (until #491 lands); D2 commit 4 says group by exact `Remediation` text. Resolve before commit 4.
- **Stale 842 baseline language everywhere**: live CI floor is `TotalCount >= 1637`, `PassedCount >= 1602` per `.github/workflows/ci.yml:128-137` + `tests/workflows/PesterBaselineGuard.Tests.ps1:28-36`. Update plan, gates, audits, #506 commit math.

### ADD these gates
- **Hard draft-only safeguard for #506 PR**: `do-not-merge` label + auto-merge off + title prefix `[DRAFT ONLY THIS CYCLE]` + reviewer-checklist line.
- **48h watchdog verification → replace with evidence-based**: N completed watchdog-triggering runs + duplicate-burst simulation + log review. Wall-clock 48h is unrealistic in this work-window.
- **G1 evidence**: every tracking issue closed by a merged PR with exit-criteria checked off.
- **Sample regeneration provenance**: explicit reproducible recipe/fixture as gate artifact (since `docs-check.yml` ignores `samples/`).
- **Sentinel ratchet for JSON-sanitize-before-parse**: PR #876 lesson not generalized; `Invoke-PRReviewGate.ps1:131-136` still does pre-parse sanitize. Add ratchet test with credential-looking JSON payloads.

## Symptom-vs-root-cause table (per-finding)

| Finding | Owner | Verdict | Severity | Fix |
|---|---|---|---|---|
| Watchdog dedup/backoff/rollup | Forge P0 | ROOT-CAUSE | Blocking | Keep; acceptance test must prove create-failure + pre-create reconciliation paths |
| Closes-link "N/A override" message tweak | Forge P1 | SYMPTOM PATCH | Non-blocking | Real fix = enumeration/retry + explicit override |
| E2E Pester retry wrap | Forge P1 | LIKELY ROOT-CAUSE | Non-blocking | OK if backed by failing path |
| Add release-please workflow | Lead P0 | INVALID/STALE | Blocking | DROP — release.yml already exists |
| Keep Test matrix advisory | Lead P1 | WRONG PREMISE | Blocking | Re-open honesty; Analyze ≠ Pester |
| Promote docs-check to required | Lead P1 | PARTIALLY VALID | Non-blocking | Expand scope first (ignores workflows/, samples/, tests/) |
| Soft-fail closes-link on 429/408 | Lead P2 | SYMPTOM/HONESTY VIOLATION | Blocking | DROP — fix retry path properly |
| CHANGELOG duplicate removal | Sage P0 | ROOT-CAUSE | Non-blocking | Keep |
| `-AlzReferenceMode` undocumented | Sage P1 | FALSE POSITIVE | — | DROP |
| `-SinkLogAnalytics` undocumented | Sage P1 | PARTLY FALSE POSITIVE | Non-blocking | Reframe as "unify cross-link & correct stale param shape" |
| Banner ready now | Sage | INVALID | Blocking | DROP |
| `Invoke-IdentityCorrelator.Tests.ps1` | Iris P1 | THIN WRAPPER | Non-blocking | Prefer thin-wrapper ratchet exemption |
| `Invoke-PRAdvisoryGate` tests | Iris P1 | ROOT-CAUSE GAP | Non-blocking | Keep |
| `RubberDuckChain` tests | Iris P1 | ROOT-CAUSE GAP | Non-blocking | Keep |

## Recommended issue strategy — 8 root-cause issues (NOT 19-25 symptoms)

1. Watchdog dedup/reconciliation RCA
2. Required-check honesty / branch-protection realignment (rebuilt on real workflow understanding)
3. Closes-link reliability (API retry + explicit override policy)
4. Docs coherence cleanup (stale 842 references + CHANGELOG dupes + sink doc cross-link)
5. Sample regeneration/provenance pipeline
6. Critical gate coverage gaps (`Invoke-PRAdvisoryGate`, `RubberDuckChain`)
7. Thin-wrapper ratchet refinement (incorporates IdentityCorrelator/CopilotTriage gracefully)
8. Track F contract clarification (#491 degradation contract + parity harness shape)

Optional: 9. Manifest ADO `source` backfill, if Track F PR needs it.

## Reordered execution plan (banner-safe)

1. **Early docs-coherence PR** (CHANGELOG dupes + 842→1637/1602 baseline language) — establishes truthful baseline
2. **Stability/reliability PRs** (watchdog dedup, closes-link API retry, JSON sanitize-after-parse ratchet)
3. **Coverage/test PRs** (PRAdvisoryGate, RubberDuckChain, thin-wrapper ratchet)
4. **Then** branch-protection realignment (only after checks themselves are trustworthy)
5. **End-to-end smoke on current main**
6. **Sample regeneration** (against final code, not stale)
7. **Final docs coherence pass**
8. **Banner-down PR**
9. **#506 draft PR** runs in parallel through whole cycle, stays draft

## Verdict

⚠️ **Land with adjustments above.** Real blockers are planning corrections, not architectural rewrites. Two biggest risks if uncorrected: (1) treating advisory Pester failures as honest green, (2) opening duplicate release-please workflow.
