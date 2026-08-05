# Decision: Batch tool pin bumps into one PR per run

**Date:** 2026-08-05
**Author:** Forge (Platform Automation & DevOps Specialist)
**Status:** Implemented

## Context

The weekly auto-update driver (tools/Update-ToolPins.ps1) ran one branch +
one commit + one PR per tool. After several weeks this produced 48 open PRs.
git merge-tree testing showed the PRs conflicted with each other in
docs/reference/tool-catalog-contributor.md (a generated file, lines 138-182),
while tools/tool-manifest.json auto-merged cleanly (changed lines 50+ apart).

## Decision

Refactor Update-ToolPins.ps1 to produce ONE batched PR per run:
- Phase 1: collect all pin changes (no git ops)
- Phase 2: single branch (chore/bump-tool-pins-<yyyyMMdd>), one commit, one PR
- Run all three doc generators once after all manifest writes
- Preserve -DryRun, breaking-change heuristic, idempotency

## Consequences

- No more PR walls from weekly automation
- Generated docs never conflict (only one copy per run)
- chore/bump- prefix preserved for closes-link-required.yml exemption
- Old per-tool branch name pattern (chore/bump-<tool>-<version>) retired