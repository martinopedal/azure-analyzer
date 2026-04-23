# PR Auto-Resolve Review Threads (Operator Runbook)

The `.github/workflows/pr-auto-resolve-threads.yml` workflow auto-resolves
inline review threads on a PR once a follow-up commit touches the file/line
range the reviewer flagged. It runs on `pull_request_target` (synchronize,
ready_for_review, reopened) and on `pull_request_review` (submitted, edited).

This document explains the auth model and how to operate the
`azure-analyzer-thread-resolver` GitHub App that powers it.

## Why a GitHub App (and not the default GITHUB_TOKEN)

The default `GITHUB_TOKEN` cannot resolve review threads it did not author.
GitHub's GraphQL `resolveReviewThread` mutation rejects bot-vs-bot resolution
with a `FORBIDDEN` error: a workflow running as `github-actions[bot]` cannot
resolve a thread opened by `copilot-pull-request-reviewer[bot]` (or any other
bot/user that is not itself), even when `pull-requests: write` is granted.

A GitHub App installation token is treated as a first-class actor and
bypasses this restriction. The app `azure-analyzer-thread-resolver` is
installed on this repository with the minimum scopes required:

- `pull_requests: write` (to call `resolveReviewThread`)
- `metadata: read` (mandatory baseline)

The workflow mints a short-lived installation token at the start of the job
via `actions/create-github-app-token`, exports it as `GITHUB_TOKEN` /
`GH_TOKEN` for the resolver step, and never persists it.

## Required repository secrets

The workflow consumes three secrets. All three must be present on
`martinopedal/azure-analyzer` for the job to succeed:

| Secret name                       | Source                                                                 |
| --------------------------------- | ---------------------------------------------------------------------- |
| `RESOLVE_THREADS_APP_ID`          | App settings page, "About" section ("App ID" field).                   |
| `RESOLVE_THREADS_INSTALLATION_ID` | App install page URL: `.../installations/<id>` (kept for future use).  |
| `RESOLVE_THREADS_PRIVATE_KEY`     | Generated PEM downloaded from the App's "Private keys" section.        |

Note: `actions/create-github-app-token` resolves the installation by
`owner` + `repositories` parameters at runtime, so the workflow itself does
not consume `RESOLVE_THREADS_INSTALLATION_ID`. The secret is kept so that
operator scripts and ad-hoc curl calls have a single source of truth.

## Operator runbook

### Locate the App

- App name: `azure-analyzer-thread-resolver`
- Owner: `martinopedal` (personal)
- Settings: https://github.com/settings/apps/azure-analyzer-thread-resolver
- Install page: https://github.com/settings/installations
  (find the installation on `martinopedal/azure-analyzer`)

### Find the App ID

Settings page > "About" section > "App ID" field. This is a small integer
(currently `3476112`). Stored in the `RESOLVE_THREADS_APP_ID` secret.

### Find the Installation ID

Open the installation in the org/personal settings page; the URL is of the
form `https://github.com/settings/installations/<id>`. The numeric `<id>`
is the installation id. Stored in the `RESOLVE_THREADS_INSTALLATION_ID`
secret.

### Rotate the private key

1. Open the App settings page.
2. Scroll to "Private keys" and click "Generate a private key". GitHub
   downloads a fresh PEM file.
3. In the repo, go to "Settings > Secrets and variables > Actions" and
   update `RESOLVE_THREADS_PRIVATE_KEY` with the full PEM contents
   (including the `-----BEGIN/END RSA PRIVATE KEY-----` lines).
4. Once the new key is verified working (re-run the workflow on a PR with
   open Copilot review threads), delete the old key from the App settings
   page.

Recommended cadence: rotate every 90 days, or immediately if the PEM was
exposed in any way.

### Disable the workflow temporarily

Set the repository variable (not secret) `SQUAD_AUTO_RESOLVE_THREADS=0`.
The job still runs but the resolver short-circuits without calling the
GraphQL mutation. Restore by setting the variable back to `1` (or
deleting it; the workflow defaults to `1`).

### Uninstall / decommission the App

1. Delete the three `RESOLVE_THREADS_*` repository secrets.
2. Disable or delete the workflow file.
3. Uninstall the App from `https://github.com/settings/installations`.
4. Optionally delete the App itself from the App settings page.

## Troubleshooting

- **Job fails with "Bad credentials"**: the PEM in `RESOLVE_THREADS_PRIVATE_KEY`
  is malformed or revoked. Regenerate per the rotation steps above.
- **Job fails with "Resource not accessible by integration"**: the App is
  installed but lacks `pull_requests: write`. Open the App settings,
  re-grant the permission, and accept the prompt on the install page.
- **Resolver runs green but threads stay open**: check the resolver's JSON
  output in the job log. The resolver only resolves threads whose file/line
  range was touched by the latest push; threads on unrelated lines are left
  for the human reviewer.
- **App not installed on a fork**: the workflow short-circuits on fork PRs
  (`head.repo.full_name != github.repository`) by design. This is a
  defense-in-depth check on top of `pull_request_target`.

## Cross-references

- Workflow: `.github/workflows/pr-auto-resolve-threads.yml`
- Resolver: `modules/shared/Resolve-PRReviewThreads.ps1`
- Comment Triage Loop / Cloud Agent PR Review contract:
  `.github/copilot-instructions.md`
- Tracking issue: `#604`
