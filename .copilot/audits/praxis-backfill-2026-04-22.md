# Praxis backfill audit — 2026-04-22

## Scope
Retroactively apply the Praxis issue-resolution verification contract (introduced in PRs #527 / #533 / #537, tracker #510) against the last 14 days of closed issues.

## Method
1. `gh issue list --repo martinopedal/azure-analyzer --state closed --search "closed:>=2026-04-08"` → 50 most recent closed issues.
2. Filter bodies for a `## Repro` section (regex `(?m)^##\s+Repro\s*$`).
3. For any match, execute the fenced `gh:` / `powershell:` block via `.github/scripts/Verify-IssueRepro.ps1` in the same guarded harness the live workflow uses.
4. Reopen with `verification-failed` label if repro still succeeds on `origin/main`.

## Findings

**Candidates with `## Repro` block: 0 / 50**

The bug-report issue template that mandates a `## Repro` block was introduced by this same feature (`.github/ISSUE_TEMPLATE/bug.yml`, PR #527). No pre-existing issue in the 14-day window carries the block, so there is nothing to retroactively verify.

## Conclusion

- Backfill is a **no-op** for this window.
- Praxis is live for all issues closed after `aa1faa6` (#537 merge). The next PR that auto-closes an issue with `Closes #N` where the issue body contains a `## Repro` block will be the first real-world execution of the contract.
- Vigil (ci-watch) has been notified of the new `verification-failed` label and the `issue-resolution-verify.yml` workflow so that any reopens are routed correctly (Hunter / Helix / Orca).

## Next trigger
First authoring agent to file a bug via the updated `bug.yml` template + land a `Closes #N`-style fix will dogfood Praxis end-to-end. If the repro block still succeeds on post-merge `main`, the issue is reopened automatically with evidence in the comment.

## References
- Tracker: #510
- PRs: #527 (initial), #533 (hardening), #537 (runtime fix)
- Workflow: `.github/workflows/issue-resolution-verify.yml`
- Helper: `.github/scripts/Verify-IssueRepro.ps1`
- Contract doc: `docs/contributing/issue-verification.md`
