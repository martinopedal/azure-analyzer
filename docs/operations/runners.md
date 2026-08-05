# Runner Topology

Self-hosted runner pools are provisioned centrally in the external `personal-runners-infra` repository (public_linux_target_repos enrollment list) and assigned based on repository visibility.

## Trust boundary

Repository visibility determines which runner pool is used:
- Public repositories use `public-*` pools (no VNet boundary) for Linux
- Private repositories use `personal-*` pools (private VNet)

azure-analyzer is a public repository enrolled in the `public-linux` pool. Windows and macOS jobs use GitHub-hosted runners: the repo is public, so hosted minutes are free and unlimited.

## Pools

| Pool Label      | Platform | Infrastructure             | Enrollment Source                                    |
|-----------------|----------|----------------------------|------------------------------------------------------|
| `public-linux`  | Linux    | ACA Pool P1                | personal-runners-infra/public_linux_target_repos     |

The `public-win` Windows VMSS pool was decommissioned on 2026-08-05. It had not dispatched jobs since approximately 2026-06-02 (no `public-win` runner registered in the org), meaning every same-repo merge in that window shipped with no Windows validation. Because the repo is public, GitHub-hosted Windows minutes cost nothing, so there is no reason to maintain a self-hosted Windows pool.

## Fork PR fallback

Jobs that dispatch on matrix OS include a fork-PR detection expression. When the PR head repository does not match the base repository (external forks), the job falls back to GitHub-hosted runners. This prevents untrusted fork PRs from executing on self-hosted infrastructure.

Trust signal expression (post-decommission):
```yaml
runs-on: >-
  ${{ github.event_name == 'pull_request' &&
      github.event.pull_request.head.repo.full_name != github.repository &&
      matrix.os
      || (matrix.os == 'ubuntu-latest' && fromJSON('["self-hosted","public-linux"]'))
      || matrix.os }}
```

Logic:
- Fork PR, any OS -> `matrix.os` (GitHub-hosted)
- Same-repo, ubuntu-latest -> `["self-hosted","public-linux"]`
- Same-repo, windows-latest -> `windows-latest` (GitHub-hosted)
- Same-repo, macos-latest -> `macos-latest` (GitHub-hosted)

## Workflow runner mapping

| Workflow Category              | Linux Runner         | Windows Runner       | macOS Runner        |
|--------------------------------|----------------------|----------------------|---------------------|
| CI (test matrix)               | `public-linux`       | GitHub-hosted        | GitHub-hosted       |
| E2E (install matrix)           | `public-linux`       | GitHub-hosted        | GitHub-hosted       |
| Release (PSGallery E2E matrix) | `public-linux`       | GitHub-hosted        | N/A                 |
| Docs check                     | `public-linux`       | N/A                  | N/A                 |
| Analyze (CodeQL Actions)       | `public-linux`       | N/A                  | N/A                 |
| Dependency review              | `public-linux`       | N/A                  | N/A                 |

## Non-matrix jobs

Jobs that do not fork-gate always run on self-hosted pools for base-repo pushes and PRs. These are single-OS jobs (typically read-only analysis or webhook-triggered jobs).

Examples:
- Docs check jobs (`docs-required`, `tool-catalog-fresh`, `permissions-pages-fresh`, `readme-facts-fresh`)
- CodeQL Analyze workflow (Actions-language scanning only)
- Dependency review workflow

All such jobs use `public-linux` because they are Linux-only jobs.

## Verification

Runner label consistency is validated at PR merge gate. Any stray `personal-*` or `public-win` label in a workflow file under `.github/workflows/` is a configuration error.

Grep command to audit:
```pwsh
Select-String -Path .github\workflows\*.yml -Pattern 'personal-(win|linux)|public-win'
```

Expected output: zero matches. Windows jobs run on GitHub-hosted (`windows-latest`); Linux self-hosted jobs reference `public-linux` only.
