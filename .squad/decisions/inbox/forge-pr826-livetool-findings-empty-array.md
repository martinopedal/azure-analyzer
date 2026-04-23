# Forge decision: PR #826 — LiveTool smoke Findings empty-array collapse fix (#770)

- **Date:** 2026-04-23
- **PR:** https://github.com/martinopedal/azure-analyzer/pull/826
- **Issue:** #770 (harden LiveTool smoke contracts vs masked warning paths)
- **Branch:** `copilot/ci-audit-github-actions-runs` (deleted on merge)
- **Final merge SHA on main:** `e6667ec`

## Root cause

The LiveTool smoke suite asserted `$result.Findings | Should -Not -Be $null` to enforce a deterministic findings collection. PowerShell unrolls an empty array `@()` over the pipeline to *zero items*, so `Should` received no input and reported failure as if the value were `$null`. Wrappers that legitimately return `Findings = @()` (gitleaks / trivy on clean inputs) therefore failed the hardened contract — the exact failure mode on the CI `LiveTool wrappers (non-blocking)` job.

## Fix

1. **`tests/wrappers/LiveTool.Wrappers.Tests.ps1`** — use the comma operator to wrap the value in an outer array so empty arrays do not collapse the pipeline:

   ```powershell
   ,$result.Findings | Should -Not -Be $null -Because '...'
   ```

   Applied in 4 places: gitleaks, trivy, zizmor, scorecard (token-present branch).

2. **Scorecard skip branch** — added the same non-null assertion alongside the existing `Count -eq 0` to close the `@($null).Count == 1` masking window flagged by Copilot review.

3. **`tests/_helpers/Capture-WrapperHostOutput.ps1`** — non-warning-like `InformationRecord` output was previously dropped entirely after the `6>&1` redirect. Now re-emitted via `Write-Information -InformationAction Continue` so debug context remains visible in Pester transcripts (Copilot review feedback).

4. **`CHANGELOG.md`** — Unreleased/Fixed entry documenting both changes.

## Copilot thread disposition (6 threads)

| Thread ID | Disposition | Evidence |
|---|---|---|
| 3131682071 | Addressed in 7c3ea5f | Scorecard skip branch now asserts non-null + Count=0 |
| 3131682122 | Addressed in 7c3ea5f | Info records re-emitted via Write-Information |
| 3131682153 | Same as 3131682122 | Re-emit covers both duplicate threads |
| 3131682184 | Addressed in d8318bd, re-confirmed in 7c3ea5f | Inline comment already documents `3>&1 6>&1` |
| 3131682207 | **Rejected** | Git blame: LiveTool README bullet has been top-level since f9975a8 / PR #697 (the LiveTool tier introduction commit). This PR did not alter list hierarchy. |
| 3131732802 | Addressed in d8318bd, re-confirmed in 7c3ea5f | Comment update already in place |

## CI narrative

- First push (7c3ea5f) only triggered `pull_request_target` workflows. `pull_request`-triggered workflows (CI, CodeQL, E2E, Docs Check, Markdown Check) failed to fire on the `synchronize` event.
- Empty re-trigger commit (1d23452) had the same behavior.
- Forced dispatch via `gh workflow run` on `ci.yml`, `codeql.yml`, `markdown-check.yml`. After those manual runs, the real `pull_request` synchronize event finally fired, and the full suite ran green on 1d23452.
- Auto-rebase workflow rebased the branch twice as main advanced; resolved via `gh pr update-branch` + wait for the 3 required checks on the final SHA (31d36f3).
- `auto-resolve` workflow failed both times (gh graphql token-scope issue). NOT a required check — does not gate merge.

## Final check state on merge SHA 31d36f3

- `Analyze (actions)` ✅
- `links (lychee)` ✅
- `lint (markdownlint-cli2)` ✅
- `LiveTool wrappers (non-blocking)` ✅ (the whole point of the PR)
- CI `Test` trio ✅ / E2E trio ✅ / Docs / Markdown / em-dash / stub-deadline / Closes-link ✅
- `auto-resolve` ❌ (auxiliary, not required)

## Local Pester baseline

2615 passed / 1 failed / 47 skipped. The lone failure is a local Windows gitleaks `Status=Failed` env quirk that also reproduces on `main` — unrelated to this PR.

## Hygiene

- CHANGELOG entry added under Unreleased / Fixed.
- No new action versions introduced (SHA-pinning preserved).
- README bullet hierarchy intentionally unchanged.
- Co-authored-by Copilot trailer on all commits.

## Commits on the merged squash

- `5b05358` test: fix LiveTool Findings assertion empty-array collapse (#770)
- `734f7cd` chore: retrigger CI on PR #826
