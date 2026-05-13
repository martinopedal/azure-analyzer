# Current Focus — azure-analyzer

## Last session: 2026-05-13T06:36Z (Consistency sweep + Track F slice 1 merge arc)

## Where we are
Two-arc cleanup landed. Repo is on `main @ e0aefe0` (post #1066).

- **PR #1080** — Archive hygiene (output-review* cleanup). **MERGED.**
- **PR #1074** — Infracost mock isolation. **MERGED.**
- **PR #1069** — RemoteClone retry/timeout wrapper. **MERGED.**
- **PR #1082** — Triage subprocess timeouts, closes #1061+#1063. **MERGED.**
  - Pivot: Orphaned CopilotTriage guarded via defensive-depth structural assertions.
- **PR #1070** — PR-gate Invoke-WithRetry, closes #1062. **MERGED.**
  - Pivot: Stranded RemoteClone bugfix surgical cherry-pick reset from origin/main.
- **PR #1077** — release-please v1.5.1. **MERGED**, tag `v1.5.1` published, PSGallery live.

## Open follow-ups (cascade complete; next session)
- **#1056** — Track F supporting modules (EdgeRelations, Select-ReportArchitecture,
  PolicyCoverageAnalyzer) referenced by Lead's plan but never landed. Blocks
  Track F slices 2-9. Lead's triage outstanding. **BLOCKING next session.**
- **#1061, #1062, #1063** — CLOSED by v1.5.1 cascade.
- **#1064** — RemoteClone baseline now in place (#1069); review for further hardening
  (logging, backoff curves, etc.). Second-priority.
- **#1065** — `LiveTool` gitleaks smoke test flake. Pre-existing; lowest priority.
- **#506** / **#1048** — Track F driver tickets (infrastructure blocker awaiting #1056).

## Next work (priority order)
1. **Triage #1056** (Lead) — infrastructure blocker for Track F slices 2-9.
2. **Harden #1064** (Atlas or Coordinator) — RemoteClone baseline now live; review logging/backoff.
3. **Investigate #1065** (Forge or Coordinator) — gitleaks flake (lowest priority, pre-existing).

## Check these on catch-up
1. `gh pr list --state open` — should be 0 squad PRs.
2. `gh issue list --label squad --state open` — should be #1056, #1064, #1065,
   plus driver tickets #506 #1048. (#1061, #1062, #1063 closed by v1.5.1.)
3. `git log --oneline -5` — top should be `9eab64a (PR #1077: release-please v1.5.1)`.

## Key files / context
- `.copilot/copilot-instructions.md` + `.github/copilot-instructions.md` —
  re-read at start of every session (conventions evolve).
- `.squad/ceremonies.md` — Comment Triage Loop (rubber-duck 3-model gate, etc.).
- `tools/tool-manifest.json` — single source of truth for tool registration.
- Session plan: `~/.copilot/session-state/28466dd2-…/plan.md` — current arc
  marked DONE.

## Directives in effect (unchanged)
- Always squash-merge with `--delete-branch`.
- Co-authored-by: Copilot trailer on every commit.
- Avoid em/en dashes in markdown (em-dash check enforces).
- LF-only line endings in PowerShell files.
- Every PR body needs `Closes #N` reference (link check enforces).
- `Invoke-WithRetry` for REST, `Invoke-WithTimeout` for CLI (300s default).
- Branch protection: only `Analyze (actions)` is required. 0 reviewers.
  Admin merge is policy-compliant.
- Self-authored agent PRs: use `gh pr merge --admin --squash --delete-branch`
  (squad-reviewer approval still required per cloud-agent contract; for solo
  maintainer this is coordinator's reasoned acceptance after CI green).
