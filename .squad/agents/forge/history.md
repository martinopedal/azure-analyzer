# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries — DevOps/Platform API checks for ALZ platform items
- **Stack:** PowerShell, Azure DevOps REST API, GitHub REST API / gh CLI, JSON
- **Created:** 2026-04-14

## Work Completed

- **2024-12-19:** SHA-pinned 10 GitHub Actions across 4 workflows (analyze, squad-triage, release, codeql)
- **2024-12-19:** Fixed copilot-instructions.md line 49 — clarified "Signed commits NOT required"
- **2024-12-19:** Refined squad-triage.yml keyword matching (robustness improvements)
- **2024-12-19:** Updated ralph-triage.js `findRoleKeywordMatch()` — improved generic keyword handling
- **2024-12-19:** Made `go:needs-research` conditional (not unconditional application)
- **2024-12-19:** Commits c588589 (SHA-pinning), 506ae8c (triage + docs + code)

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->
- CI failure dedup key uses hash format `sha256("{workflow}|{first-error-line}")` truncated to 12 chars for stable issue-title matching.
- Self-skip pattern for `workflow_run` watchers should include workflow-name exclusion to avoid recursive self-processing.
- Repeated CI failures should comment `still failing — {run_url}` on the open hash-matched issue instead of creating duplicates.
- Treat `workflow_run` payload fields as untrusted input: pass through `env` and reference shell variables in `run:` blocks to reduce expression-injection risk.
- workflow_run payload does not expose 'head_branch'; branch checks in watchdog logic must use API lookup or avoid branch gating in job-level expressions.


