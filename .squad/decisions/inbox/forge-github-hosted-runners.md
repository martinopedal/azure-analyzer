# Decision: Migrate all workflows to GitHub-hosted runners

**Date:** 2026-08-05
**Author:** Forge (CI/CD agent)
**PR:** #1256
**Status:** Implemented

## Context

The `public-linux` self-hosted runner pool (ACA Pool P1) reached 0 registered runners.
`gh api repos/martinopedal/azure-analyzer/actions/runners` returned `total_count: 0`.

47 workflow runs were queued indefinitely. The oldest had been stuck for 58+ minutes.
Three PRs (#1252, #1254, #1255) and multiple squad agents were blocked.

## Decision

Migrate all 26 workflow files from self-hosted runners to GitHub-hosted runners entirely.

## Rationale

1. **Public repo - free runners:** This repo is public. GitHub-hosted runners are free and unlimited for public repos. There is no cost reason to maintain a self-hosted pool.
2. **Zero registered runners:** With 0 runners in the pool, all jobs queued indefinitely. No PR could ever go green.
3. **Simpler topology:** Fork-PR ternary expressions (choosing between GitHub-hosted for forks and self-hosted for same-repo) are no longer needed. All branches get the same runner.
4. **Precedent:** PR #1250 already migrated the Windows side (public-win pool). This completes the Linux side.

## Three patterns removed

- Pattern A: `runs-on: [self-hosted, public-linux]` - replaced with `runs-on: ubuntu-latest`
- Pattern B: fork-PR ternary resolving to the pool - collapsed to `runs-on: ubuntu-latest`
- Pattern C: multi-line matrix dispatch routing ubuntu-latest to the pool - simplified to `runs-on: ${{ matrix.os }}`

## Outcome

All 26 workflow files now use GitHub-hosted runners exclusively. The self-hosted pool
infrastructure is no longer referenced and can be fully decommissioned.

## Constraints going forward

- Never reintroduce self-hosted runner references without first verifying active runners exist
- Check `gh api repos/.../actions/runners` before assuming the pool is active
- This repo is public - GitHub-hosted minutes are always the right default
