# Decision: exempt release/bot actors from `Closes Link Required` CI gate

- **Date:** 2026-04-23
- **Agent:** Forge
- **PR:** [#835](https://github.com/martinopedal/azure-analyzer/pull/835) (merged)
- **Issues:** #833, #852

## Problem

The `Closes Link Required` workflow (`.github/workflows/closes-link-required.yml`) false-failed on:

- release-please release PRs (no tracked issue, head branch `release-please--branches--main`)
- dependabot, copilot-swe-agent, github-actions bot-authored PRs
- PRs explicitly labeled `skip-closes-check`

These PRs cannot reasonably carry a `Closes #N` link, yet the required status check blocked merges and triggered downstream flake loops.

## Decision

Bypass the closes-link requirement when any of the following is true:

1. PR has label `skip-closes-check`.
2. Head branch matches `/^release-please--/`.
3. PR author is in the explicit allowlist: `dependabot[bot]`, `copilot-swe-agent[bot]`, `copilot-swe-agent`, `Copilot`, `github-actions[bot]`.

Otherwise enforcement continues: PR body must contain `Closes|Fixes|Resolves #N`, an issues URL, or an explicit `N/A` justification, with a pure-docs auto-exemption via `listFiles`.

## Guardrails

- All five skip conditions are covered by `tests/workflows/ClosesLinkRequired.Tests.ps1` (5/5 green baseline).
- Does **not** change the error-path message — non-bot PRs still see the same actionable error.
- Does **not** widen docs auto-exemption patterns.
- Uses the GitHub webhook payload (no extra API calls) for the fast path, so rate-limit exhaustion cannot falsely block well-formed PRs.

## Operational lesson captured

- PRs authored by `copilot-swe-agent[bot]` trigger the repo's "bot actor approval" gate: all workflow runs land in `action_required` until a maintainer either clicks "Approve and run workflows" in the UI or pushes a commit as themselves. The fork-approval API (`POST /actions/runs/{id}/approve`) rejects internal runs with HTTP 403. **Workaround: maintainer pushes a commit on the branch** — subsequent runs execute without approval. Document this in the cloud-agent PR contract if it recurs.

## Follow-ups

- Issues #833 and #852 can be closed as resolved by #835.
- Consider adding `release-please[bot]` as a further allowlisted author once release-please is upgraded to push under that actor.
