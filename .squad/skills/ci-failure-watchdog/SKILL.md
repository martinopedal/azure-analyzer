# CI Failure Watchdog Pattern

## Intent

Turn failed GitHub Actions runs into deduplicated bug issues that stay updated while failures persist.

## Trigger

- `workflow_run` with `types: [completed]`
- Guard: run only when conclusion is `failure`
- Self-skip: exclude the watchdog workflow by name

## Core Pattern

1. Pull failed-run logs (`gh run view <id> --log-failed`, bounded to first 500 lines)
2. Extract first error line with regex `(?i)(error|failed|fatal):`
3. Compute hash: first 12 chars of `sha256("{workflow}|{first-error-line}")`
4. Dedup open issues by searching hash in title under `ci-failure` label
5. Comment if existing issue found, else create labeled issue

## Security Invariants

- Pass untrusted workflow payload fields via environment variables.
- Sanitize error text before writing to disk or issue bodies.
- Keep least-privilege workflow permissions (`issues:write`, `actions:read`, `contents:read`).
