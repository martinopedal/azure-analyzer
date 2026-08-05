# Current Focus - azure-analyzer

## Last session: 2026-08-05T14:00Z (Windows Runner Migration & Native Suppression List)

## Where we are

✅ **Windows CI restored.** Issue #1173 closed via PR #1250 (e09ad611). Switched windows-latest from dead public-win self-hosted VMSS pool to GitHub-hosted runners. First green Windows CI validation in 2 months. Zero Windows regressions found.

✅ **Native false-positive suppression list shipped.** Issue #1229 closed via PR #1251 (4704a3c). Shipped modules/shared/Suppression.ps1, unit tests, and docs. Fixed live production bug where missing finding properties caused PropertyNotFoundException under Set-StrictMode -Version Latest.

✅ **Tool-pin PR backlog deduped.** Consolidated 48 stacked tool-pin PRs down to 16 unique tools. Closed 31 superseded PRs with --delete-branch and forced branch updates on open keepers against fixed workflows.

🔄 **In flight:** Background worktrees active for #1230 and #1225.

**Repo status:** main @ 4704a3c.

## Open issues (priority order)

1. **#1230** - IN FLIGHT (Forge, background worktree azure-analyzer-1230).

2. **#1225** - IN FLIGHT (Forge, background worktree azure-analyzer-1225).

3. **#1231** - QUEUED (depends on #1230).

## Next work (priority order)

1. Complete #1230 and #1225 in-flight streams.

2. Execute #1231 upon completion of #1230.

3. Process 16 remaining tool-pin PR updates.

## Key files / context

- .copilot/copilot-instructions.md + .github/copilot-instructions.md - re-read at start of every session.
- .squad/ceremonies.md - Comment Triage Loop (rubber-duck 3-model gate).
- tools/tool-manifest.json - single source of truth for tool registration.

## Directives in effect

- Always squash-merge with --delete-branch.
- Co-authored-by: Copilot trailer on every commit.
- Avoid em/en dashes in markdown (em-dash check enforces).
- LF-only line endings in PowerShell files.
- Every PR body needs Closes #N reference.
- Invoke-WithRetry for REST, Invoke-WithTimeout for CLI (300s default).
- Branch protection: only Analyze (actions) required. 0 reviewers. Admin merge is policy-compliant.
- Self-authored agent PRs: use gh pr merge --admin --squash --delete-branch (squad-reviewer approval still required per cloud-agent contract; for solo maintainer this is coordinator's reasoned acceptance after CI green).