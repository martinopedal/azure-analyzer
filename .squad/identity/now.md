# Current Focus — azure-analyzer

## Last session: 2026-05-13T06:36Z (Consistency sweep + Track F slice 1 merge arc)

## Where we are
Two-arc cleanup landed. Repo is on `main @ e0aefe0` (post #1066).

- **PR #1060** — Wrapper envelope `Errors=@()` consistency sweep (13 wrappers),
  EnvelopeContract regex tightened, `CliTimeout` sanitization gap closed,
  `CopilotTriage` exception hardening, +28 new tests. **MERGED.**
- **PR #1055** — release-please 1.4.7. **MERGED**, tag `v1.4.7` published.
- **PR #1057 → #1066** — Track F slice 1 (narrowed dep gate + auditor context
  + executive summary). #1057 was inadvertently closed in a race with the
  release-please cascade; rebased clean and re-opened as **#1066**, admin-merged
  as `e0aefe0`. **MERGED.**
- **#1059** consistency-sweep tracking issue auto-closed.

## Open follow-ups (squad label, none blocking)
- **#1056** — Track F supporting modules (EdgeRelations, Select-ReportArchitecture,
  PolicyCoverageAnalyzer) referenced by Lead's plan but never landed. Blocks
  Track F slices 2-9. Lead's triage outstanding.
- **#1061** — wrap Python triage subprocess with `Invoke-WithTimeout`.
- **#1062** — wrap PR review-gate external calls in `Invoke-WithRetry`.
- **#1063** — wrap `gh copilot` CLI calls in `Invoke-WithTimeout`.
- **#1064** — refactor `RemoteClone.ps1` to use `Invoke-WithRetry` +
  `Invoke-WithTimeout`.
- **#1065** — `LiveTool` gitleaks smoke test fails only inside full Pester suite
  (state leak from a prior test). Pre-existing flake, not introduced by recent
  arcs.
- **#506** / **#1048** — Track F driver tickets (slice 1 done in #1066, rest
  blocked on #1056).

## Next work (priority order)
1. Triage **#1056** (Lead) so Track F slices 2-9 can resume.
2. Pick off **#1061** + **#1063** together (both are 1-line `Invoke-WithTimeout`
   wrap-ups; coordinator inline, no agent spawn needed).
3. Then **#1062** (multiple call-sites, route to Atlas).
4. Then **#1064** (RemoteClone refactor, route to Atlas).
5. **#1065** is lowest priority — investigate state leak when convenient.

## Check these on catch-up
1. `gh pr list --state open` — should be 0 squad PRs.
2. `gh issue list --label squad --state open` — should be #1056, #1061-#1065,
   plus driver tickets #506 #1048.
3. `git log --oneline -5` — top should be `e0aefe0 (PR #1066)`.

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
