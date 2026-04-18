# Copilot Instructions - azure-analyzer

## Development Process

All code changes follow this pipeline:

1. **Build** - implement on a feature branch, run tests locally
2. **Review Gate** - 3-model code review (Opus 4.6 + Goldeneye + GPT-5.3-codex)
   - All 3 must APPROVE before merge
   - Parse-check all .ps1 files, verify no ?. syntax, check error handling
3. **Fix** - address all findings from reviewers
4. **Re-gate** - re-run review with the models that rejected, verify fixes
5. **Final Review Gate** - if re-gate passes, proceed. If not, loop back to Fix
6. **CI** - all GitHub Actions must pass (CodeQL, docs-check)
7. **Merge** - squash merge to main, delete feature branch

## Automated Review Ingestion

When a PR gets `CHANGES_REQUESTED`, or when Copilot/human review comments are added, the `pr-review-gate.yml` workflow triggers automatically. It ingests PR reviews/comments, builds a 3-model triage bundle (Claude premium + GPT codex + Goldeneye), writes the consensus plan to `.squad/decisions/inbox/`, and posts a PR summary comment with ownership and next actions. Reviewer Rejection Lockout is automatic, the rejected PR author agent is mechanically locked out from doing the revision in that gate cycle, and the consensus must name a different revision owner.

## Squad PRs — Draft by Default (#113)

Squad agents MUST open PRs as drafts to suppress reviewer-request emails during iteration:

```bash
gh pr create --draft --base main --head <branch> --title "..." --body "Closes #<n> ..."
```

Flip a draft PR to ready-for-review only when ALL of the following hold:
- CI is green
- The PR body contains a filled-in `## Self-review` section (#110)
- No unresolved advisory findings remain (#109)

The squad coordinator (or the PR author agent, after self-review) marks the PR ready via `gh pr ready <pr>`. Do not open non-draft PRs from agent workflows.

## Code Quality Rules

- PS 7.4+ only. No ?. null-conditional on variables
- $using: in ForEach-Object -Parallel must be copied to local vars before indexing
- All error paths must use Remove-Credentials for sanitization
- All CLI tool wrappers must check $LASTEXITCODE
- Use temp files for CLI JSON output, not stdout capture with 2>&1
- Every tool wrapper returns Status (Success/Failed/Skipped/PartialSuccess)
- Trivy: verify binary from official releases only (https://github.com/aquasecurity/trivy/releases)

## Documentation Rules

- Every PR that changes code must update README, CHANGELOG, PERMISSIONS.md as applicable
- Docs are rubber-ducked against actual code before merge
- No em dashes in any documentation

## Squad Pre-PR Self-Review (mandatory)

Every squad agent MUST produce a `## Self-review` section in the PR body **before** calling `gh pr create`. This is a policy gate (CI enforcement deferred to follow-up): PRs without it should be amended immediately. Enforced manually by the Squad coordinator and PR reviewers until the CI check (#future) is built. The section compresses what changed, what could break, and what was tested so the reviewer (human or Copilot) does not start from zero.

**Required template (paste into PR body, fill all fields):**

```markdown
## Self-review

### Diff summary
- {bullet 1: what changed at a high level}
- {bullet 2}
- {bullet 3}

### Risks considered
- {risk 1}: {mitigation, or "accepted because ..."}
- {risk 2}: ...
- Out of scope on purpose: {what was deliberately NOT touched}

### Testing
- Ran: {test command(s) and pass/fail counts, e.g. `Invoke-Pester -Path .\tests -CI` → 542/542}
- Added: {new tests, or "none, doc/template-only change"}
- Skipped: {tests that don't apply}, {reason, or "n/a"}
```

**Rules:**
- Diff summary is **3 bullets max**, to force compression.
- Risks must include at least one "out of scope on purpose" line so reviewers know what the agent consciously left alone.
- Testing must name the actual command run, not "tests pass".
- Doc-only and template-only PRs still need this section. List "none, doc-only" under Added and the relevant test command (or `n/a`) under Ran.
- This applies to every squad member without exception, including the Lead.
