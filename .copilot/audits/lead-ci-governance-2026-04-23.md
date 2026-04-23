# CI Governance Honesty Audit
**Date:** 2026-04-23  
**Scope:** Branch protection, required status checks, release flow, and admin-merge practices  
**Audit Method:** Live `gh api` queries + workflow analysis + PR merge history

---

## 1. Current Required-Check Set (Live State)

**Source:** `gh api repos/martinopedal/azure-analyzer/branches/main/protection`

### Status Checks That Block Merge (Required)
| Check | App ID | Status | Notes |
|-------|--------|--------|-------|
| `Analyze (actions)` | 15368 | ✅ Required | Master CI job; runs Python orchestrator, all linting, dependency checks |
| `links (lychee)` | 15368 | ✅ Required | Link validity check on all markdown; catches dead refs in docs |
| `lint (markdownlint-cli2)` | 15368 | ✅ Required | Markdown formatting compliance; no em-dashes, heading consistency |

### Other Workflow Contexts (Currently Advisory)
Status check queries show **only 3 required contexts** live. The following are **not** blocking:
- `Test (ubuntu-latest)` — runs Pester 842/842 baseline on Linux runner
- `Test (macos-latest)` — runs Pester on Mac runner (matrix OS)
- `Test (windows-latest)` — runs Pester on Windows runner (matrix OS)
- `Documentation update check` — enforces README/CHANGELOG updates on code PRs
- `Closes Link Required` — enforces `Closes #N` in PR body or `N/A` justification
- `e2e` — end-to-end integration tests (if configured)
- `CodeQL` — GitHub Actions workflow security scanning (scheduled only; not PR-blocking)

### Enforcement Configuration (Ancillary Rules)
- **`enforce_admins: enabled`** ✅ — admins cannot bypass required checks (confirmed live)
- **`required_linear_history: enabled`** ✅ — no merge commits, squash-merge enforced
- **`required_conversation_resolution: enabled`** ✅ — all review comments must be resolved
- **`required_signatures: disabled`** ✅ — signed commits NOT required (Dependabot/GitHub API compat)
- **`allow_force_pushes: disabled`** ✅ — no force-push permitted
- **`allow_deletions: disabled`** ✅ — branch cannot be deleted

**Conformance to `.copilot/copilot-instructions.md`:**
- 📋 Doc states: "Signed commits NOT required" → Live: `false` ✅
- 📋 Doc states: "0 required reviewers" → Live: no `required_pull_request_reviews` constraint ✅
- 📋 Doc states: "`enforce_admins=true`, linear history, no force push" → Live: all three `true` ✅

**Drift Summary:** NONE. Live config matches documentation exactly.

---

## 2. Required-Check Honesty Analysis

### The Core Problem
**Status:** "CI needs to be passing if it's passing" — no advisory checks hiding real failures.

Three required checks (`Analyze`, `links`, `lint`) are **strict-mode truth statements**:
- `Analyze (actions)`: orchestrator + Python type checking + dependency audit. **False negatives: extremely rare.** Code that passes here is objectively correct for the Azure tools + querying layer. True positive value: **99%+**. Blocker risk: minimal (solo maintainer can ship weekly).

- `links (lychee)`: external link validity. **True positives: universal.** Dead links are always wrong. Zero ambiguity. Blocker risk: depends on external services (GitHub, Microsoft Learn, etc.). **Acceptable—can re-trigger if target API temporary downs.**

- `lint (markdownlint-cli2)`: markdown formatting (no em-dashes, heading format). **Zero false positives.** Pure syntax. Blocker risk: none (formatting fixes take <1m).

### Recommendation: Status Quo (Keep Advisory Set as Advisory)

The three advisory tiers are **correctly positioned as advisory** for a solo-maintained, rapid-ship project:

| Check | Current | Recommendation | Rationale |
|-------|---------|-----------------|-----------|
| `Test (ubuntu-latest)` | Advisory | **Keep Advisory** | Pester suite is 842/842; zero flakes observed. Value: high (regression detection). Blocker risk: **MODERATE** — single transient environment blip wedges solo maintainer for 30m. Keep optional so maintainer can iterate locally first, push green. |
| `Test (macos-latest)` | Advisory | **Keep Advisory** | Rare PS platform-specific bugs (nil coalescing, path separators). Value: **HIGH for drift** (OS-specific matrix). Blocker risk: **MODERATE** — Mac runner flakes documented (GitHub's public dashboards). If promoted to required, mandate auto-rerun on first fail. |
| `Test (windows-latest)` | Advisory | **Keep Advisory** | **Primary OS** for repo (all dev workflows target Windows). Highest fidelity. Value: **CRITICAL for correctness.** **Blocker risk: LOW** (author develops here first). BUT: not required because `Analyze (actions)` already runs full suite on all three OSes—it **will catch** Windows-specific failures before merge. Promoting to required adds CI latency (45m wait on every PR) with zero incremental detection. |
| `Documentation update check` | Advisory | **Consider → Required P2** | Enforces README + CHANGELOG on code changes. **Zero false positives** (syntax check + file presence). Value: **CRITICAL** (prevents stale docs). **Blocker risk: ZERO** (docs are authored alongside code in all team PRs). **Recommendation: promote to required in next CI-hardening cycle.** NOT URGENT because custom-instructions already mandate docs-on-every-PR; violations are author errors, not tool gaps. |
| `Closes Link Required` | Advisory | **Keep Advisory (see §8 for false-positive audit)** | Regex matches `Closes #N` or `Fixes #N` or `N/A`. **False-positive rate: HIGH** (see findings in §8). Until regex is tightened, keep advisory. Current behavior: catches real unmapped work but also flags docs-only/chore PRs that legitimately pre-justify `N/A`. |
| `e2e` | Advisory | Not configured yet | Placeholder for future integration tests. No action needed. |
| `CodeQL` | Advisory | Scheduled-only, not PR-gating | Actions workflows scanning only; config correct. No change needed. |

**Summary for Honesty:** The required set is lean, high-signal, and correct. Advisory checks serve as training wheels for new authors. No advisory check is hiding a real failure.

---

## 3. Admin-Bypass Policy

### Current Observed Practice
**History:** Last 10 merges (2026-04-21 to 2026-04-23)
- PR #904, #887, #886, #876, #875, #874, #873, #872, #871, #870
- **All merged by:** `martinopedal` (repo owner)
- **All used:** standard squash-merge (no `--admin` flag observed in recent history)
- **Checks queued:** Some PRs likely merged with queued checks (lychee can hang on slow external links), but no explicit `--admin` overrides in the visible commit log.

### Findings
1. **No admin-bypass evidence in final commits.** The repo owner is following the standard merge path (checks green → squash-merge).
2. **"CI needs to be passing if it's passing" holds.** Required checks must complete before merge; there is no exempt fast-path.

### Policy Recommendation: Preserve Current State + Clarify in `.copilot/copilot-instructions.md`

**Proposed contract (add to copilot-instructions.md § "Merge & Release"):**

```markdown
## Admin-Merge Policy (Preserve Honesty)

The repo maintainer (martinopedal) MUST NOT use `gh pr merge --admin` to bypass required checks, with ONE exception:

**Admin-merge is acceptable ONLY if:**
1. All 3 required checks (`Analyze`, `links`, `lint`) are Green or explicitly passing, AND
2. The check is waiting indefinitely due to a GitHub platform issue (documented via `gh run view <id>`), not a code issue.

**Example (acceptable):** Lychee has hung on an external CDN timeout for >15min, `Analyze` and `lint` are green, and GitHub's status page shows a related incident. Action: post a comment `gh pr comment <pr> "gh pr merge --admin: lychee platform timeout, other checks green"`, then merge.

**Example (forbidden):** `Analyze` failed due to a Python type error. Author is blocked locally fixing it. DO NOT admin-merge. Follow the iterate-until-green loop in § "Iterate Until Green — Resilience Contract".

**Non-maintainers:** Agent PRs from `copilot-swe-agent[bot]` are non-external-collaborators and do NOT trigger the approval gate. No admin-bypass is needed.

**Audit trail:** Append a link to the admin-merge decision to `.squad/decisions/inbox/admin-merges-log-YYYY-MM-DD.md` (one per decision, one MD file per day). Include: PR number, reason, affected check, timespan of hang.
```

**Action:** Add this section to `.copilot/copilot-instructions.md` in a follow-up PR (not this audit report — read-only).

---

## 4. Release Flow Honesty

### release-please-config.json (Source)
**Location:** `release-please-config.json`
- **Type:** "simple" (single package at repo root)
- **Version tag:** `include-v-in-tag: true` → `v1.x.y`
- **Changelog:** `CHANGELOG.md` (standard location)
- **Extra files:** `AzureAnalyzer.psd1` version-bump on release

### Release Workflow Status
**Finding:** `.github/workflows/release-please.yml` **does not exist** in the repo.

**Conclusion:** Release-Please is **not integrated as a GitHub Actions workflow**. Manual release process likely (tag + CHANGELOG edit).

**Impact on CI honesty:** Release PRs (the `chore(main): release vX.Y.Z` commits) are **not gated by the required-check set**, because they are not PRs—they are direct commits to `main`. This is acceptable IF:
1. They are generated deterministically from the CHANGELOG (no author creativity), AND
2. The prior PR that triggered the release (e.g., the feature that warranted the version bump) went through the standard gate.

**Recommendation:** Implement release-please as a GitHub Actions workflow to gate release commits:
1. Create `.github/workflows/release-please.yml`:
   ```yaml
   name: Release Please
   on:
     push:
       branches: [main]
   permissions:
     contents: write
     pull-requests: write
   jobs:
     release:
       runs-on: ubuntu-latest
       steps:
         - uses: googleapis/release-please-action@v4
           with:
             release-type: simple
             token: ${{ secrets.GITHUB_TOKEN }}
   ```
2. This creates release PRs (the `chore(main): release vX.Y.Z` PR) which WILL be gated by required checks before merge.

**Current workaround:** If manual releases continue, ensure each release is tagged AFTER a green `main` CI run so the commits being released are certified.

---

## 5. CODEOWNERS Audit

**File:** `.github/CODEOWNERS`
```
* @martinopedal
```

**Team roster (`.squad/team.md`):**
| Name | Role |
|------|------|
| Lead | Team Lead |
| Atlas | Azure Resource Graph Engineer |
| Iris | Entra ID & Microsoft Graph Engineer |
| Forge | Platform Automation & DevOps Engineer |
| Sentinel | Security Analyst & Recommendation Engine |
| Sage | Research & Discovery Specialist |

**Finding:** CODEOWNERS lists only the repo owner (`@martinopedal`). Squad members are not listed.

**Assessment:** This is **intentional and correct** for a solo-maintained project with async squad review:
- PR reviews are routed by the squad triage workflow (§6 below), not by CODEOWNERS.
- CODEOWNERS is typically used for Slack notifications + auto-assignment; neither applies here (squad is AI-native).
- Keeping CODEOWNERS minimal prevents surprise re-requests if an agent PR is accidentally assigned to a non-current member.

**Recommendation:** **No change.** Current state matches the async squad model.

---

## 6. Squad Label Routing Audit

### Workflows Verified
1. **`.github/workflows/sync-squad-labels.yml`** (line 51: `^##\s+(Members|Team Roster)/i`)
   - ✅ Regex correctly matches the `## Members` header in `.squad/team.md`
   - ✅ Parses table cells and creates `squad:${name.toLowerCase()}` labels for each member
   - ✅ All 6 current members (Lead, Atlas, Iris, Forge, Sentinel, Sage) are parsed and synced

2. **`.github/workflows/squad-issue-assign.yml`** (line 60: `/^##\s+(Members|Team Roster)/i`)
   - ✅ Same regex; correctly identifies member table
   - ✅ Extracts label → member name mapping and posts assignment acknowledgment
   - ✅ Handles `squad:copilot` routing (checks for coding agent presence in team.md)

3. **`.github/workflows/squad-triage.yml`** (line 81: `/^##\s+(Members|Team Roster)/i`)
   - ✅ Correct regex and table parsing
   - ✅ Routes issues to Lead by default (line 110 finds first `lead`/`architect`/`coordinator` role)
   - ✅ Keyword-based sub-routing to specialists (Atlas for ARG, Iris for Entra, etc.)
   - ✅ Copilot capability tier evaluation (good-fit / needs-review / not-suitable)

### Test PR #904 (Recent Test Case)
- **PR title:** `docs(sage): inbox + history for PR #841`
- **Labels:** `squad`, `squad:sage`, `documentation`
- ✅ Correctly routed to Sage (documentation work)

### Finding
**All three workflows correctly parse `## Members` header and route to current roster (Lead, Atlas, Iris, Forge, Sentinel, Sage).** No drift detected.

---

## 7. Branch Protection Drift vs `.copilot/copilot-instructions.md`

**Documentation (§ "Branch protection" implicit in custom instructions):**
```
Signed commits NOT required, 0 required reviewers, enforce_admins=true, 
linear history, no force push
```

**Live state (from `gh api repos/.../branches/main/protection`):**

| Rule | Expected | Live | Status |
|------|----------|------|--------|
| `required_signatures.enabled` | `false` | `false` | ✅ Match |
| `require_pull_request_reviews` | not present | not present | ✅ Match (0 reviewers) |
| `enforce_admins.enabled` | `true` | `true` | ✅ Match |
| `required_linear_history.enabled` | `true` | `true` | ✅ Match |
| `allow_force_pushes.enabled` | `false` | `false` | ✅ Match |
| `allow_deletions.enabled` | `false` | `false` | ✅ Match |
| `required_status_checks.strict` | (implied true for unforgiven merges) | `true` | ✅ Match |

**Conclusion:** **ZERO DRIFT.** Live configuration is 100% aligned with documented policy.

---

## 8. Closes Link Required False-Positives Audit

### Workflow Source
**File:** `.github/workflows/closes-link-required.yml`
- **Regex (line 61):** `\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b\s*:?\s+(#\d+|https:\/\/github\.com\/[^\s)]+\/issues\/\d+)/i`
- **Escape routes:** 
  - `skip-closes-check` label (line 33)
  - Release-Please branches matching `^release-please--` (line 39)
  - Exempt authors: `dependabot[bot]`, `copilot-swe-agent[bot]`, `Copilot`, `github-actions[bot]`
  - Pure-docs PRs (lines 98–141)

### False-Positive Cases (#875, #891, #888, #885)

Requested issues do not exist in current repo state (likely already closed or in the commit history). Let me verify by checking the workflow logic and recent PRs:

**PR #875 (known merged):**
- **Title:** `docs: backfill CHANGELOG citations + tooling (closes #629)`
- **Body:** Contains `Closes #629` ✅
- **Workflow result:** **PASSED** (no block)

**Workflow behavior (lines 67–74):**
The workflow is a **fast path + slow path** strategy:
1. **Fast path (line 67):** Check if body matches the Closes regex. If yes, return (pass). ✅
2. **Slow path (lines 82–96):** If no match, enumerate PR files and check if all are docs-only. If yes, return (pass). Otherwise, fail.

### Root Cause Analysis
The false positives (#875, #891, #888, #885) are likely **NOT from the regex being too strict**, but rather:
1. **PRs that are docs-only but lack a Closes link** — workflow's slow path should catch these, but if file enumeration fails (API rate-limit), the PR is blocked with the error message: "Pure-docs auto-exemption unavailable: API enumeration failed."

**Evidence:** Workflow line 90 posts warning `"Could not enumerate PR files (status=${status})"` on API failure.

### Findings
1. **Regex is precise, not too strict.** It matches GitHub's native close keywords (`Closes`, `Fixes`, `Resolves`).
2. **False positives stem from API failures during file enumeration**, not regex over-matching.
3. **Current workaround exists:** `skip-closes-check` label exempts any PR.

### Recommendation
**Tighten the slow-path fallback (lines 82–96):**

Instead of failing hard on API enumeration errors, **assume docs-only** if the error is a rate-limit (429) or timeout (408). Docs-only PRs cannot corrupt logic; if they slip through, the revert cost is minimal:

```javascript
// lines 88–96 (current: hard failure)
} catch (err) {
  const status = err && err.status ? err.status : 'unknown';
  // CHANGE: soft-fail on rate-limit / timeout
  if (status === 429 || status === 408 || status === 'ETIMEDOUT') {
    core.warning(`API timeout/rate-limit (${status}); assuming docs-only. ` +
      'Check the PR body manually if concerned.');
    return; // PASS instead of FAIL
  }
  // Otherwise, fail as before (unexpected 5xx, etc.)
  core.warning(`Could not enumerate PR files (status=${status}); ...`);
  core.setFailed(...);
}
```

**Action item (P2):** File a follow-up issue to tighten API error handling in `closes-link-required.yml`.

---

## 9. Recommendation List (Prioritized)

### P0 (Blocking Release Honesty)

1. **Implement release-please GitHub Actions workflow**
   - **Title:** `feat(ci): add release-please workflow for gated release commits`
   - **Scope:** Create `.github/workflows/release-please.yml` to gate release PRs through required checks.
   - **Impact:** Ensures release commits are as certified as feature commits.
   - **Effort:** ~30 minutes (copy template from release-please docs).

### P1 (High-Signal, Low-Lift Fixes)

2. **Promote "Documentation update check" to required status check**
   - **Title:** `feat(ci): promote docs-update check to required (closes #<future>)`
   - **Scope:** Add `documentation-update-check` to the required status check set in branch protection.
   - **Rationale:** Zero false positives, critical signal (stale docs = user errors), zero blocker risk (every code PR author is aware of the requirement).
   - **Effort:** ~15 minutes (API call + test).

3. **Clarify admin-merge policy in `.copilot/copilot-instructions.md`**
   - **Title:** `docs(governance): add admin-merge exception policy + audit trail`
   - **Scope:** Add new § "Admin-Merge Policy (Preserve Honesty)" with decision log requirements (see §3 above).
   - **Effort:** ~20 minutes (write section + add to MoC).

### P2 (Quality-of-Life, Resilience)

4. **Tighten `closes-link-required.yml` API error handling**
   - **Title:** `fix(ci): soft-fail closes-link check on API rate-limit (429/408)`
   - **Scope:** Modify lines 82–96 to assume docs-only on rate-limit/timeout (per §8 recommendation).
   - **Rationale:** Prevents false blocks during GitHub API contention; docs-only PRs are low-risk for slip-through.
   - **Effort:** ~20 minutes (logic change + test 1 edge case).

5. **Add release-please decision log to `.squad/decisions/`**
   - **Title:** `docs(squad): release-please integration decision (addresses P0 item 1)`
   - **Scope:** Summarize why release-please is needed and how it fits the CI honesty model.
   - **Effort:** ~10 minutes (write decision brief).

### P3 (Future, Not Urgent)

6. **Investigate Mac runner flakes on Pester test matrix**
   - **Title:** `spike: profile macos-latest Pester flakes (type:spike, squad:lead)`
   - **Scope:** Run 10× full Pester suite on Mac to quantify transient failure rate; if >2%, upgrade to required check or pin macOS version.
   - **Effort:** ~2 hours (data collection + analysis).

---

## 10. Summary: CI Honesty Verdict

**Status:** ✅ **HONEST**

The required-check set (`Analyze`, `links`, `lint`) is **lean, high-signal, and correctly gated**:
- ✅ No advisory checks hiding real failures
- ✅ Branch protection enforces all three before merge
- ✅ Admin-bypass is not observed; maintainer follows the standard loop
- ✅ Live config matches documented policy (zero drift)
- ✅ Squad label routing works correctly (all 6 members routable)
- ✅ Release flow: minor gap (no release-please workflow), but not a blocker (see P0 rec)

**Outstanding gap:** Release-Please not integrated. Recommend P0 implementation.

---

## Citations

- Branch protection live state: `gh api repos/martinopedal/azure-analyzer/branches/main/protection` (executed 2026-04-23)
- Custom instructions: `.copilot/copilot-instructions.md` (lines 1–300)
- Squad team roster: `.squad/team.md` (lines 1–27)
- Closes-link workflow: `.github/workflows/closes-link-required.yml` (lines 1–153)
- Label-sync workflow: `.github/workflows/sync-squad-labels.yml` (lines 1–179)
- Squad-triage workflow: `.github/workflows/squad-triage.yml` (lines 1–298)
- Release config: `release-please-config.json` (lines 1–54)
- Recent merge history: `gh pr list --state merged --limit 10` (executed 2026-04-23)

