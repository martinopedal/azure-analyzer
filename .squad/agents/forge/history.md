# Forge Agent History

## Sessions

### 2026-08-05 - Issue #1173: Windows GitHub-hosted runner migration

**Task:** Close #1173. Move `windows-latest` off the decommissioned self-hosted `public-win` VMSS pool and onto GitHub-hosted runners.

**Context established:**
- No `public-win` runner registered since ~2026-06-02. Only `runner-public-linux-ac19d2-18948` (labels: `self-hosted,Linux,X64,public-linux`) was registered.
- Every same-repo `Test (windows-latest)` and `e2e (windows-latest)` job queued indefinitely and was cancelled. Fork PRs were unaffected (fork branch of the ternary resolves to `matrix.os`).
- Two months of same-repo merges shipped with zero Windows validation.

**Files changed:**
- `.github/workflows/ci.yml` - removed `|| (matrix.os == 'windows-latest' && fromJSON('["self-hosted","public-win"]'))`, updated dispatch comment block (line ~22) and Az-module comment (line ~77)
- `.github/workflows/e2e.yml` - removed `public-win` branch
- `.github/workflows/release.yml` - removed `public-win` branch (this file has no fork-PR guard, only the ubuntu/windows branches)
- `docs/operations/runners.md` - full rewrite documenting new topology
- `CHANGELOG.md` - entry added under `## Unreleased / ### Fixed`

**Result:** PR #1250, merged at `e09ad611d02cc92f7492ab8588e1542d96ed48cc`. Issue #1173 auto-closed.

**CI outcome:**
- `Test (windows-latest)` passed in 5m40s on first run after fix. No Windows-specific breakage was found.
- `e2e (windows-latest)` passed in 1m20s.
- All other checks green. Required check `Analyze (actions)` green.

## Learnings

### Runner topology (post-2026-08-05)

- `ubuntu-latest` same-repo -> `["self-hosted","public-linux"]` (ACA Pool P1)
- `windows-latest` same-repo -> `windows-latest` (GitHub-hosted, decommissioned public-win pool)
- `macos-latest` same-repo -> `macos-latest` (GitHub-hosted, no macOS pool was ever registered)
- Fork PR, any OS -> `matrix.os` (GitHub-hosted)

The `public-win` VMSS pool is decommissioned as of 2026-08-05. Never reference it in workflow files.

### release.yml dispatch pattern

`release.yml` (around line 363) uses a simpler dispatch expression with no fork-PR guard (release jobs only run on the base repo). After the fix it reads:
```yaml
${{ (matrix.os == 'ubuntu-latest' && fromJSON('["self-hosted","public-linux"]'))
    || matrix.os }}
```

### Windows-only breakage

None found. `Test (windows-latest)` went green immediately after the dispatch fix, suggesting no accumulated Windows-only regressions during the two months of skipped validation.

### Key file paths

- Workflow dispatch expressions: `.github/workflows/ci.yml`, `.github/workflows/e2e.yml`, `.github/workflows/release.yml`
- Runner topology docs: `docs/operations/runners.md`
- Az module install step (self-hosted public-linux needs this; GitHub-hosted ships Az bundle): ci.yml around line 67
### 2026-08-05 - Team Update
- **Team Update (2026-08-05):** Windows CI restored on GitHub-hosted runners (PR #1250 / #1173). Native false-positive suppression list shipped (PR #1251 / #1229). Backlog of 48 tool-pin PRs deduped down to 16 keepers.


### 2026-08-05 - Linux runner migration (PR #1256)

Task: Migrate all remaining public-linux self-hosted references to GitHub-hosted runners.

Context: The public-linux pool reached 0 registered runners. 47 workflow runs queued indefinitely. Three PRs (#1252, #1254, #1255) blocked. This completed the work started by #1250 (Windows side).

Result: PR #1256. --admin merge required (chicken-and-egg: no runner to run required check until this lands).

## Learnings

### Runner topology (post-2026-08-05 full migration)

The self-hosted pool is fully deregistered (0 runners). This repo is now 100% GitHub-hosted.
- ubuntu-latest -> GitHub-hosted (free on public repos)
- windows-latest -> GitHub-hosted
- macos-latest -> GitHub-hosted

Three runner patterns that accumulated and were removed:
1. Pattern A - plain array: runs-on: [self-hosted, public-linux] - single-job workflows
2. Pattern B - fork-PR ternary resolving to the pool on same-repo branches
3. Pattern C - multi-line matrix dispatch in ci.yml, e2e.yml, release.yml

Never reintroduce self-hosted runner references without first verifying the pool has active runners.


## Learnings (2026-08-05 - batch-tool-pins session)

**merge-tree conflict-detection technique:** Running git merge-tree origin/main pr/A pr/B before merging reveals whether two branches conflict. Run it across all adjacent pairs of stacked PRs to build a conflict map before committing to a merge strategy. This was the empirical test that proved the 48-PR wall was non-viable sequentially.

**generated-docs-are-the-conflict-surface:** When a generated file (docs/reference/tool-catalog-contributor.md) is committed alongside source changes, it becomes the conflict surface for concurrent PRs, not the source file. The source (tool-manifest.json) had 50+ lines between each change and auto-merged cleanly; the generated doc had all 16 changes in lines 138-182 with four adjacent-line pairs that conflicted. Solution: batch all changes into one PR so there is only one set of generated docs to commit.

**batching fix pattern:** Refactor a per-item loop that does branch+commit+PR inside the loop into two phases: (1) collect all changes, (2) create one branch, apply all changes, run generators once, open one PR. This is the canonical pattern for any tool that auto-bumps dependencies weekly.
