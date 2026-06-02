# Runner Topology

Self-hosted runner pools are provisioned centrally in the external `personal-runners-infra` repository (public_linux_target_repos and public_windows_github_repo_list enrollment lists) and assigned based on repository visibility.

## Trust boundary

Repository visibility determines which runner pool is used:
- Public repositories use `public-*` pools (no VNet boundary)
- Private repositories use `personal-*` pools (private VNet)

azure-analyzer is a public repository enrolled in the `public-*` pools.

## Pools

| Pool Label      | Platform | Infrastructure             | Enrollment Source                                    |
|-----------------|----------|----------------------------|------------------------------------------------------|
| `public-linux`  | Linux    | ACA Pool P1                | personal-runners-infra/public_linux_target_repos     |
| `public-win`    | Windows  | VMSS Pool W-pub            | personal-runners-infra/public_windows_github_repo_list |

## Fork PR fallback

All workflow jobs that dispatch on matrix OS (ubuntu-latest / windows-latest) include a fork-PR detection expression. When the PR head repository does not match the base repository (external forks), the job falls back to GitHub-hosted runners (ubuntu-latest / windows-latest literal labels) instead of self-hosted pools. This prevents untrusted fork PRs from executing on the self-hosted infrastructure.

Trust signal expression:
```yaml
runs-on: >-
  ${{ github.event_name == 'pull_request' &&
      github.event.pull_request.head.repo.full_name != github.repository &&
      matrix.os
      || (matrix.os == 'ubuntu-latest' && fromJSON('["self-hosted","public-linux"]'))
      || (matrix.os == 'windows-latest' && fromJSON('["self-hosted","public-win"]'))
      || matrix.os }}
```

## Workflow runner mapping

| Workflow Category              | Linux Runner         | Windows Runner       | macOS Runner        |
|--------------------------------|----------------------|----------------------|---------------------|
| CI (test matrix)               | `public-linux`       | `public-win`         | GitHub-hosted       |
| E2E (install matrix)           | `public-linux`       | `public-win`         | GitHub-hosted       |
| Release (PSGallery E2E matrix) | `public-linux`       | `public-win`         | N/A                 |
| Docs check                     | `public-linux`       | N/A                  | N/A                 |
| Analyze (CodeQL Actions)       | `public-linux`       | N/A                  | N/A                 |
| Dependency review              | `public-linux`       | N/A                  | N/A                 |

## Non-matrix jobs

Jobs that do not fork-gate (direct runner assignment without the trust expression) always run on self-hosted pools for base-repo pushes and PRs. These are single-OS jobs that have no fork-PR risk surface (typically read-only analysis or webhook-triggered jobs).

Examples:
- Docs check jobs (`docs-required`, `tool-catalog-fresh`, `permissions-pages-fresh`, `readme-facts-fresh`)
- CodeQL Analyze workflow (Actions-language scanning only)
- Dependency review workflow

All such jobs use `public-linux` because they are Linux-only jobs.

## Verification

Runner label consistency is validated at PR merge gate. Any stray `personal-*` label in a workflow file under `.github/workflows/` that is not accompanied by the repo-visibility trust expression is a configuration error and will cause self-hosted runner acquisition to fail on public-repo CI.

Grep command to audit:
```pwsh
Select-String -Path .github\workflows\*.yml -Pattern 'personal-(win|linux)'
```

Expected output: zero matches. All self-hosted jobs should reference `public-linux` or `public-win`.
