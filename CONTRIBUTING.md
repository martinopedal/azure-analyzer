# Contributing

> AI governance: see [docs/contributor/ai-governance.md](docs/contributor/ai-governance.md).

This is a solo-maintained repository. Contributions are welcome but the maintainer reviews and merges everything.

## Process

1. Fork the repo
2. Create a branch: `git checkout -b feat/your-change`
3. Make your changes
4. Sign off your commit: `git commit -s -m "feat: describe your change"`
5. Open a pull request against `main`

## Adding a new tool

Adding a new assessment tool requires three components:

1. **Collector** (`modules/Invoke-{ToolName}.ps1`) -- wraps the tool and returns raw findings
2. **Normalizer** (`modules/normalizers/Normalize-{ToolName}.ps1`) -- converts raw output to schema v2 FindingRow format using `New-FindingRow` from `modules/shared/Schema.ps1`
3. **Manifest entry** (`tools/tool-manifest.json`) -- registers the tool for orchestration

See [docs/contributor/adding-a-tool.md](docs/contributor/adding-a-tool.md) for the full wrapper contract, normalizer template, and testing checklist.

## AI-assisted contributions

AI-assisted contributions are welcome. If you used an AI tool to generate or refactor code, disclose it in the PR description using the pull request template. The maintainer will verify correctness before merging.

## Commit sign-off

All commits must include a `Signed-off-by` trailer. Use `git commit -s` to add it automatically. This certifies that you wrote the contribution or have the right to submit it under the project license.

## Review

PRs are reviewed by the maintainer. There are no required reviewers beyond the maintainer. `enforce_admins` is enabled, so branch protection applies to everyone including the maintainer.

## CI workflows and squad infrastructure (maintainer-only)

These workflows support repo development and the AI squad workflow. They're not relevant if you're only running the tool.

| Workflow | Trigger | Purpose |
|---|---|---|
| `codeql.yml` | Push / PR / weekly | CodeQL static analysis (SHA-pinned) |
| `docs-check.yml` | PR | Enforces docs updates with code changes (non-final stacked PR parts titled `(PR-x of y)` are skipped) |
| `markdown-link-check.yml` | PR (`*.md` path filter) / weekly | Checks markdown links via `.lychee.toml` and reports failures in job summary |
| `pr-review-gate.yml` | `pull_request_review` + `_comment` | Ingests review feedback, writes consensus plan to `.squad/decisions/inbox/`, posts gate summary |
| `ci-failure-watchdog.yml` | `workflow_run` on failure | Deduplicated CI failure issue (hash = workflow + first error line) |
| `squad-heartbeat.yml` | Cron | Automated triage and CI gate via Ralph |
| `squad-triage.yml` | Issue events | Routes issues to squad members |
| `squad-issue-assign.yml` | Label event | Assigns issues to squad agents |
| `sync-squad-labels.yml` | Push | Syncs squad labels |
| `auto-label-issues.yml` | Issue opened | Adds `squad` label |

Set `SQUAD_WATCH_CI=1` to opt into the local polling helper (`tools/Watch-GithubActions.ps1`) that applies the same dedup loop outside GitHub Actions.

To run markdown link checks locally: `lychee --config .lychee.toml './**/*.md'`

The `.squad/` directory contains AI team infrastructure for automated triage and development. It is **not** part of the tool itself and is excluded from archive downloads.
