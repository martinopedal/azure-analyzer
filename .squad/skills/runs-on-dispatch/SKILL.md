---
name: "runs-on-dispatch"
description: "Pattern for dispatching GitHub Actions jobs to self-hosted or GitHub-hosted runners based on fork status and matrix OS"
domain: "ci/cd"
confidence: "high"
source: "azure-analyzer ci.yml, e2e.yml, release.yml"
---

## Context

This repo uses self-hosted runners for Linux (ACA pool `public-linux`) and GitHub-hosted runners for Windows and macOS. Because the repo is public, GitHub-hosted minutes are free and unlimited. A self-hosted Windows pool (`public-win`) was decommissioned 2026-08-05 after failing to dispatch for two months.

Fork PRs must not run on self-hosted infrastructure (untrusted code). The dispatch expression gates on fork status.

## The pattern (ci.yml / e2e.yml - jobs with fork-PR guard)

```yaml
runs-on: >-
  ${{ github.event_name == 'pull_request' &&
      github.event.pull_request.head.repo.full_name != github.repository &&
      matrix.os
      || (matrix.os == 'ubuntu-latest' && fromJSON('["self-hosted","public-linux"]'))
      || matrix.os }}
```

Logic trace:
- Fork PR, any OS -> `matrix.os` (GitHub-hosted, safe for untrusted code)
- Same-repo, ubuntu-latest -> `["self-hosted","public-linux"]`
- Same-repo, windows-latest -> `windows-latest` (GitHub-hosted)
- Same-repo, macos-latest -> `macos-latest` (GitHub-hosted)

## Simpler pattern (release.yml - no fork-PR guard needed)

Release jobs only run on the base repo (tag pushes). No fork-PR detection required.

```yaml
runs-on: >-
  ${{ (matrix.os == 'ubuntu-latest' && fromJSON('["self-hosted","public-linux"]'))
      || matrix.os }}
```

## Adding a new self-hosted pool

To add a new pool (e.g. a future Windows pool):
1. Register the runner in `personal-runners-infra` enrollment list.
2. Add a branch to the dispatch expression: `|| (matrix.os == 'windows-latest' && fromJSON('["self-hosted","public-win"]'))`.
3. Update `docs/operations/runners.md` pool table.
4. Verify the runner label appears in the org runner list before merging.

## Anti-patterns

- Never add a `public-win` or `personal-win` branch without a registered runner. The job will queue forever and be cancelled.
- Never use `personal-*` labels in this public repo. The VNet-private pools are for private repos only.
- Never remove the fork-PR guard from `ci.yml` or `e2e.yml`. Untrusted fork code must not run on self-hosted infrastructure.
