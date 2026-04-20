# Atlas - PR-1 Foundation Restructure complete

**Timestamp:** 2026-04-20T14:50:00Z
**Agent:** Atlas (claude-sonnet-4.6 in this run; charter-assigned model claude-opus-4.7)
**PR:** [#243](https://github.com/martinopedal/azure-analyzer/pull/243) - squash-merged
**Merge commit:** `ed6041d07068c990f5fa0dded25f39be5d836870`
**Branch:** `docs/restructure-foundation` (deleted post-merge)
**Worktree:** `C:\git\worktrees\restructure-foundation` (removed)

## Scope delivered (PR-1 of 5)

- 9 doc moves under `docs/consumer/` and `docs/contributor/` via `git mv` (history preserved through `git log --follow`).
- Text-only "Moved" stub at every old path (no meta-refresh; trio-confirmed sanitizer behavior).
- New `docs/consumer/README.md` and `docs/contributor/README.md` index pages.
- One-line AI-governance pointer added near top of `CONTRIBUTING.md`.
- `.github/workflows/docs-check.yml` detection logic patched: `docs/consumer/**` and `docs/contributor/**` recognized as docs paths; root `AI_GOVERNANCE.md` entry removed; failure message updated.
- `.squad/v2-roadmap-draft.md` link reference updated to new path.

## Authority limits respected

- README.md, SECURITY.md, PERMISSIONS.md, CHANGELOG.md untouched (PR-2 / PR-5 will own).
- AzureAnalyzer.psm1 / .psd1 untouched (PR-4 / Forge).
- report-template.html untouched (deferred / orphan investigation).

## Em-dash gate

`rg -- "-"` over all 12 changed/new `.md` files: zero hits.

## Checks (PR #243)

11/11 green on first push; no iteration required. Required check `CodeQL/Analyze (actions)`: green in 55s.

## Success metric verification

- `rg "docs/ARCHITECTURE|docs/CONTRIBUTING-TOOLS|docs/continuous-control|docs/sinks/log-analytics|docs/ai-triage|docs/gitleaks-pattern-tuning|docs/future-iac-drift|docs/proposals/copilot-triage-panel|AI_GOVERNANCE"` post-merge: only intentional stubs at old paths plus pre-existing references in README/PERMISSIONS/CHANGELOG (resolve via stubs, owned by later PRs in this series).
- All 11 PR checks green.
- PR merged.

## Follow-ups for downstream PRs

- **PR-2 (README rewrite):** README still links to `docs/continuous-control.md`, `docs/sinks/log-analytics.md`, `docs/ARCHITECTURE.md`, `docs/CONTRIBUTING-TOOLS.md`, `docs/gitleaks-pattern-tuning.md`. Update to new paths.
- **PR-2 / PR-5:** PERMISSIONS.md and CHANGELOG.md still link to `docs/ARCHITECTURE.md` and `docs/ai-triage.md`. PR-5 (Sentinel) is the natural place for PERMISSIONS link freshening if not done in PR-2; CHANGELOG entries are historical and stay as-is unless explicitly part of the new entry.
- **Stub retention:** filed implicitly via stub text "through the next minor release"; recommend a follow-up issue to remove the 9 stub files after the next minor tag.

## Skill extracted

`.squad/skills/repo-link-sweep/SKILL.md` - reusable workflow for safe repo-wide link sweeps when relocating docs.
