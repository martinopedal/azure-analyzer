# Decision: Bot gate solution (#938)

**Date:** 2026-04-24
**Author:** Forge
**PR:** #956

## Context

Bot-authored PRs (release-please, tool-auto-update) and rebase pushes using
`GITHUB_TOKEN` had two compounding problems:

1. **First-time-contributor approval gate** — GitHub treats `github-actions[bot]`
   as requiring manual workflow-run approval, blocking CI on every bot PR.
2. **Anti-recursion guard** — pushes/PR-creates done with `GITHUB_TOKEN` never
   trigger downstream `on: pull_request` / `on: push` workflows.

The old auto-approve-bot-runs.yml was deleted (PR #937) because the
`POST /actions/runs/{id}/approve` API is fork-PR-only (HTTP 403 on in-repo bots).

## Decision

Extend the GitHub App token pattern (introduced in PR #955 for release-please)
to `tool-auto-update.yml` and `pr-auto-rebase.yml`. Reuse the same App
(`RELEASE_APP_ID` / `RELEASE_APP_PRIVATE_KEY`) — no new App installation needed.

Read-only downstream workflows (ci.yml, docs-check.yml, markdown-check.yml,
codeql.yml, closes-link-required.yml) do NOT need App tokens; they benefit
from the upstream fix automatically.

## Residual: copilot-swe-agent[bot]

`copilot-swe-agent[bot]` creates PRs externally (GitHub product), not via a
repo workflow. The App token fix cannot apply there. The residual mitigation
is that once a GitHub user with the Copilot actor association merges a PR,
GitHub registers them as a contributor and the gate resolves permanently.

## Status

Accepted — PR #956.
