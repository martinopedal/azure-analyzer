# Copilot PR thread auto-resolution

`pr-auto-resolve-threads.yml` resolves review threads after follow-up commits modify the flagged lines.

## Root-cause fix for bot-vs-bot `FORBIDDEN`

GitHub's `resolveReviewThread` GraphQL mutation can reject bot-owned thread resolution when called with the default `GITHUB_TOKEN` identity (`github-actions[bot]`), even with `pull-requests: write`.

To avoid this, the workflow now requires a dedicated secret token:

- Secret name: `RESOLVE_THREADS_TOKEN`
- Expected token source: GitHub App installation token (or equivalent non-bot write identity)
- Required scope: `pull_requests:write` on this repository

The workflow exports this secret as `GH_TOKEN` for `modules/shared/Resolve-PRReviewThreads.ps1` and fails fast when the secret is missing.

## Operational notes

- `SQUAD_AUTO_RESOLVE_THREADS=0` still disables the resolver.
- Failures are now fatal again; no `continue-on-error` soft-fail path remains.
- Keep all workflow actions SHA-pinned.
