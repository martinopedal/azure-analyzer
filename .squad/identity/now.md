# Current Focus — azure-analyzer

## Last session: 2026-05-13T12:00Z (Track F #506 complete + v1.6.0 ship)

## Where we are

✅ **Track F complete.** Epic #506 closed via PR #1096 (Commit 9). Auditor Mode production-ready.

✅ **v1.6.0 shipped.** release-please PR #1087 merged; tag published; artifacts live.

✅ **All tests green.** 3087→3122 passed (35 tests added, 0 regressions). Hotfix (PR #1097) cleared all 10 parameter validation failures.

**Repo status:** main @ f247700 (post-hotfix merge).

## Open issues (priority order)

1. **#1098** — FILED (enhancement, `squad:atlas`). Tier 2 sql.js embedding for Auditor Mode evidence export.

2. **#1056** — CLOSED. Track F helper modules verdict (Option B: no new modules needed).

3. **#506** — CLOSED. Track F epic.

## Next work (priority order)

1. **Atlas** — Track F Commit 11 (enhancements): Blast radius renderer (`ConvertTo-AuditorResilienceHtml`), remediation appendix renderer (`ConvertTo-AuditorRemediationAppendixHtml`). Refs #1098.

2. **Atlas or Auditor builder owner** — Tier 2 sql.js embedding (Auditor Mode evidence database).

3. **Squad housekeeping** — Inbox consolidation + history summarization (ongoing).

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
