# Forge completion record - issue #245

- Issue: #245
- PR: #256
- Merge commit: 515ea9205326f8735b66f6bc45c51e154bdc99db
- Closed at: 2026-04-20T14:40:59Z

## Root cause
Docs Check required doc updates on every stacked PR part, so non-final parts (for example, `PR-4 of 5`) failed and only emitted `core.setFailed` output that the CI-failure watcher could not consistently fingerprint.

## Fix
Updated `.github/workflows/docs-check.yml` to skip docs enforcement for non-final stacked PR titles `(PR-x of y)` and emit explicit `error:` lines before failure, then documented behavior in `README.md`, `CONTRIBUTING.md`, and `CHANGELOG.md`.
