# Docs Restructure Shipped via PR #418

**Date**: 2026-04-23
**Status**: Shipped (commingled with v2 HTML report PR1)
**PR**: [#418](https://github.com/martinopedal/azure-analyzer/pull/418)

## What Landed

Complete docs restructure per forge-docs-restructure-proposal:
- New tree: `docs/getting-started/`, `docs/guides/`, `docs/reference/`, `docs/operators/`, `docs/contributing/`, `docs/architecture/`, `docs/decisions/`
- Reshaped root README.md to ~50-line visible contract with collapsed sections
- New reference pages: `orchestrator-params.md`, `etl-pipeline.md`
- All 40+ permission pages moved to `docs/reference/permissions/`
- Generator scripts updated to emit catalogs at new paths
- CI workflow `docs-check.yml` updated for new paths
- CHANGELOG entry, CONTRIBUTING.md and azure-function/README.md links updated
- Pester baseline maintained (1501 passed, 0 failed, 5 skipped)

## Lesson: Branch Confusion in Parallel Agent Runs

This work was committed to Iris's `feat/v2-html-report-pr1-foundations` branch instead of a standalone `docs/restructure-progressive-disclosure` branch due to both agents sharing the same checkout directory in the same session. Commits from forge's work tree interleaved with Iris's work and landed on her branch.

**Fix for future runs**: All parallel agents in the same repository MUST use distinct worktrees (`git worktree add`) or be strictly serialized. See `.squad/agents/forge/history.md` and memory-vault pattern for details.

**Outcome**: Despite the branch interleaving, all work is in PR #418 and drove toward green. Iris owns merge. No rework needed.
