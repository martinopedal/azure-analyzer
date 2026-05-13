# Current Focus — azure-analyzer

## Last session: 2026-05-13T10:39Z (Inbox flush post #1085 #1086)

## Where we are
Two PRs merged. Repo is on `main @ 94f5801` (post #1086).

- **PR #1085** — release-please v1.5.2 release cycle. **MERGED.**
- **PR #1086** — Issue #1056 triage (Option B: consume renderers directly). **MERGED.**

## Open issues (priority order)

1. **#1056** — CLOSED by PR #1086 verdict (Option B: helper modules are naming mismatches, not gaps). Track F slices 2–9 unblocked. Mapper: EdgeRelations → Schema.ps1; Select-ReportArchitecture → ReportManifest.ps1; PolicyCoverageAnalyzer → Policy/AlzMatcher.ps1 + PolicyEnforcementRenderer.ps1.

2. **#506** — Track F epic (now actionable). Slice 2+ can proceed against as-built renderer layout.

3. **#1084** — CI digest (Forge, historical noise). Medium priority.

4. **#1065** — `LiveTool` gitleaks smoke test flake (pre-existing). Lowest priority.

## Next work (priority order)

1. **Atlas** — Pick up Track F slice 2 (control-domain sections). Consume `Schema.ps1` `New-FindingRow` ComplianceMappings directly. Refs #506.

2. **Forge** — Audit #1084 CI digest, dedupe historical entries from real failures.

3. **Forge or Coordinator** — Investigate #1065 gitleaks flake (lowest priority, pre-existing).

## Key files / context

- `.copilot/copilot-instructions.md` + `.github/copilot-instructions.md` — re-read at start of every session.
- `.squad/ceremonies.md` — Comment Triage Loop (rubber-duck 3-model gate).
- `tools/tool-manifest.json` — single source of truth for tool registration.

## Directives in effect

- Always squash-merge with `--delete-branch`.
- Co-authored-by: Copilot trailer on every commit.
- Avoid em/en dashes in markdown (em-dash check enforces).
- LF-only line endings in PowerShell files.
- Every PR body needs `Closes #N` reference.
- `Invoke-WithRetry` for REST, `Invoke-WithTimeout` for CLI (300s default).
- Branch protection: only `Analyze (actions)` required. 0 reviewers. Admin merge is policy-compliant.
- Self-authored agent PRs: use `gh pr merge --admin --squash --delete-branch` (squad-reviewer approval still required per cloud-agent contract; for solo maintainer this is coordinator's reasoned acceptance after CI green).