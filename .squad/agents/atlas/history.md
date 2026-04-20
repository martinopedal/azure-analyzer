# Project Context

- **Owner:** martinopedal
- **Project:** azure-analyzer - Automated Azure assessment bundling azqr, PSRule, AzGovViz, and ALZ Resource Graph queries
- **Stack:** Python (orchestrator), KQL/ARG queries (JSON), PowerShell, GitHub Actions
- **Created:** 2026-04-15

## Learnings

- ARG queries live in `queries/` as JSON files, not .kql files
- Every query must return a `compliant` column (boolean)
- Query schema reference: alz-graph-queries repo
- All Azure tool invocations are read-only (Reader role only)
- Output is written to `output/` directory which is gitignored

## 2026-04-19 Session Outcomes

- Issue #166 delivered and merged via PR #182 (`6bb07aec6277a04ff3ed1a412eb5155fbcf16944`).
- Added Azure DevOps repo secret scanning and pipeline run-log correlation with wrapper/normalizer tests and fixtures.
- Updated docs in the same change set (`README.md`, `PERMISSIONS.md`, `CHANGELOG.md`) per repo rules.
- Noted `rubberduck-gate` degraded/advisory failure path and linked fix in `modules/shared/Get-CopilotReviewFindings.ps1` (owner/repo normalization for GraphQL calls).
- Post-merge follow-ups opened for deferred ADO scope:
  - #197 Azure DevOps Server/on-prem support
  - #198 Private-repo access edge cases
  - #199 Advanced gitleaks pattern strategy

## 2026-04-20 PR-1 Foundation Restructure (PR #243, squash-merge ed6041d07068c990f5fa0dded25f39be5d836870)

### Outcome
Landed PR-1 of the 5-PR consumer-first documentation restructure: 9 doc moves under `docs/consumer/` and `docs/contributor/`, redirect stubs at every old path, two new index pages, `docs-check.yml` pattern updates, and a one-line AI-governance pointer in `CONTRIBUTING.md`. All 11 checks green on first run, no iteration loop required.

## Learnings

- **Em-dash gate** is real and zero-tolerance. `rg -- "-"` over every changed `.md` before commit. Stub template uses hyphens only.
- **`docs-check.yml` detection model** is an inline `actions/github-script` JS snippet at `.github/workflows/docs-check.yml` lines ~38-74. Two structures matter: `ignoredPatterns` (regex array; what is NOT code) and `isDoc` predicate (originally a flat string array). Patching for the new tree means converting `isDoc` to `rootDocs.includes(f) || docPathPatterns.some(p => p.test(f))` so `docs/consumer/**` and `docs/contributor/**` count as docs. Failure message also referenced the old set; updated to mention the split tree.
- **Link sweep gotcha**: `git mv` followed by writing a stub at the old path defeats git's automatic rename detection in `git status` (shows as "M old + A new" instead of "R old -> new"). History is still preserved because `git log --follow` runs rename detection at log time and the stub (~200 chars) is below similarity threshold vs the moved doc. Acceptable trade-off for stubs; for pure moves, commit the rename first and add stubs in a follow-up commit.
- **Authority limits trump the "patch every hit" sweep instruction.** README/PERMISSIONS/CHANGELOG had hits to moved paths but were explicitly off-limits in this PR; stubs at old paths cover those references for now and PR-2/3 will rewrite README. Reading the authority block carefully prevents scope creep.
- **Parallel `git commit` calls collide on `index.lock`.** Sequential commits only. The collision left state inconsistent (commit subject didn't match content); had to recover by adding the missing files in a third commit. Always serialize index-mutating git operations.
- **Inbound-link search** in this repo (post-restructure): `rg` excluding `.squad/agents/*/history.md`, `.squad/log/**`, `.squad/orchestration-log/**` is the correct boundary. Those three globs are append-only personal/historical logs and outdated paths there are truth, not bugs.
- **The known `modules/Invoke-ADORepoSecrets.ps1` line-595 hit referenced in the task brief no longer exists.** No PowerShell module references any of the moved doc paths. Worth re-confirming with `rg` rather than trusting line-numbered hints in task briefs.
- **Required check is `Analyze (actions)`** (CodeQL). All other checks (CI matrix, Docs Check, Verify install manifest, advisory gate, Copilot review request, rubberduck-gate) ran green too. `rubberduck-gate` reports "Gate skipped: non-squad-author" when the PR author is martinopedal directly - expected on solo runs.



## 2026-04-20T13-12-02Z - PR-2 (consumer-first README rewrite) #246, merged `e2d42d7`

Shipped PR-2 of the doc-restructure stream: rewrote root README from 660 to 126 lines (target `<200`). First scroll = badges + value prop + install + 3 quickstart scenarios (full Azure assessment, cloud-first remote-repo CI/CD scan, generate HTML report). Canonical install `Import-Module .\AzureAnalyzer.psd1; Invoke-AzureAnalyzer`; documented `Install-Module AzureAnalyzer` with the user-approved `# coming in vNEXT once published to PSGallery` footnote. Cloud-first ordering preserved.

**Merged on first try** - all 9 required checks green, no iterate-until-green loop needed. No Copilot threads opened.

**Learnings:**
- Atlas-task-prompt link constraint (`links must resolve post PR-1`) trumped the consolidated-plan suggestion of placeholder links to PR-3 pages. Routed all to-be-extracted-page references through the existing `docs/consumer/README.md` index. Net effect: README ships clean today; PR-3 lands the deep pages and a small follow-up can swap index links for direct ones.
- `CHANGELOG.md` already contained pre-existing em dashes from prior entries. Interpreted the em-dash gate as `new content I add must not contain em dashes` (verified) rather than `the file must contain zero em dashes anywhere` (would require touching unrelated history). The gate held.
- Used a non-frontier model for this task (sonnet-4.5 via the CLI host) since it was a pure docs rewrite with no model-gated review path; result was clean. For PR-3 / PR-5 stick to the frontier roster per `copilot-instructions`.
- Worktree cleanup: `git worktree remove` complains about `main` already being used elsewhere when run from inside the to-be-removed worktree; running it from `C:\git\azure-analyzer` works cleanly.

## 2026-04-20 - PR-3 (consumer-first restructure, items G/H/I/J/K)

PR #247, merged as `be665ea`.

Built `scripts/Generate-ToolCatalog.ps1` (manifest-driven, idempotent, `-CheckOnly`) plus 14-test Pester file. Generated `docs/consumer/tool-catalog.md` and `docs/contributor/tool-catalog.md`. Wrote `docs/contributor/operations.md` and `troubleshooting.md` distilled from `modules/shared/*.ps1` headers (NOT from README - PR-2 owns that). Added `tool-catalog-fresh` job to docs-check.yml. Swept stale paths in PERMISSIONS.md / CONTRIBUTING.md / docs-check.yml. Updated both index pages.

### War story: `0` leak across test files

Initial CI showed ubuntu+windows Test jobs red on `Get-CopilotReviewFindings.Tests.ps1`. First instinct was "pre-existing flake" because main was green and tests passed in isolation locally. Wrong. Real root cause: my new test `CheckOnly fails when stale` invokes the generator with synthetic stale fixtures, script exits 1, `0 = 1` leaks into the Pester runspace. Alphabetically `tests/scripts/...` runs before `tests/shared/...`, and `Resolve-PRReviewThreads.ps1` line 74-78 samples `0` after a mocked `gh` call - throws `gh api graphql failed` even with valid JSON. Fix: reset `0 = 0` in the failing test's `finally` block plus a top-level `AfterAll`. 5 lines, one file.

**Lesson:** any Pester test that invokes a script expected to exit non-zero MUST reset `0` or every subsequent test in the run that touches it becomes a victim. `\| Out-Null` does not reset exit code.

**Lesson:** "pre-existing CI flake" is a tempting label - I should compare against the same SHA on main first (which I did), but if that says green, the flake conclusion is wrong and the leak is mine.

### Item H no-op

PERMISSIONS.md / CHANGELOG.md / CONTRIBUTING.md / SECURITY.md kept at root - squad automation hardcodes these paths. Documented in PR body and completion record.

### Follow-ups recorded in completion file

- `.copilot/skills/architectural-proposals/SKILL.md` has 19 pre-existing em-dashes + stale `docs/proposals/` path
- README pruning candidate now that `operations.md` / `troubleshooting.md` exist


## 2026-04-20 - Issue #252: PERMISSIONS.md split (PR #257, merged as 7b34e71)

Trimmed root PERMISSIONS.md from 867 -> 116 lines. Hybrid approach: per-tool prose (tables, sample commands, what-it-does/does-not blocks) hand-extracted to 27 dedicated pages under docs/consumer/permissions/<tool>.md (26 enabled + copilot-triage). 5 cross-cutting framework pages (_summary / _continuous-control / _multi-tenant / _management-group / _troubleshooting) + folder README. Index inside PERMISSIONS.md is manifest-driven via scripts/Generate-PermissionsIndex.ps1 between BEGIN/END markers, gated by new permissions-pages-fresh CI job (mirrors tool-catalog-fresh). 11 Pester tests, all green. Pester baseline 1208/1208/5-skipped.

### War story: workflows did not trigger on first push

Pushed PR #257, only 2 of the expected ~14 checks ran (PR Advisory Gate + Copilot Agent PR Review, both pull_request_target). Docs Check, CodeQL, CI - all on pull_request - did not trigger. `gh pr view` showed mergeStateStatus=DIRTY, mergeable=CONFLICTING. Root cause: my branch was based on an older main (2a9d75d) and the rebase against current main (095b7dd) had a CHANGELOG conflict because PR #249 had landed an Unreleased > Removed entry while I added an Unreleased > Permissions entry to the same section. GitHub silently suppresses pull_request workflow runs while the merge ref is in conflict; pull_request_target still fires because it runs against base. Resolved CHANGELOG manually (kept both subsections; mine first, then Removed), force-pushed, all 14 checks then ran and went green. Lesson: `gh pr view --json mergeStateStatus` is the first thing to check when "checks did not trigger" - DIRTY is the symptom of a silent conflict-suppression of pull_request events.

### War story: required check is "Analyze (actions)", not "CodeQL/Analyze (actions) (pull_request)"

First merge attempt failed with "2 of 2 required status checks are expected" even though the rollup showed all 14 green. Branch protection requires contexts named exactly `rubberduck-gate` and `Analyze (actions)` - GitHub native CodeQL setup posts that exact short context name in addition to the workflow-prefixed one. Both eventually arrived; second attempt after second rebase against main (PR #256 had landed in the meantime) merged cleanly with --admin --squash --delete-branch.

### Lessons

- For docs that mix index-style (uniform per-tool) and narrative-style (rich prose) content: hybrid wins. Use the manifest for the index, keep prose hand-curated, gate page-existence with CI. Same pattern as PR-3 tool catalog.
- The Comment Triage Loop / 3-model gate did not run because PR was non-squad-author; rubberduck-gate was skipped intentionally.
- One `Get-Date -Format "yyyy-MM-ddTHH-mm-ssZ"` in PowerShell gives a perfect ISO-Z slug for decisions inbox files.
- Always rebase before merge if --admin is being used; `mergeStateStatus` in PR JSON is the canonical signal.


## 2026-04-20 - Issue #230 framework matrix

Implemented framework x tool coverage matrix in New-HtmlReport with click-to-filter, manifest frameworks[] source-of-truth, regenerated tool catalogs + permissions index, and added report tests (full suite 1294 pass / 5 skipped).
