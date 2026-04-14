# Copilot Instructions — azure-analyzer

## Repository Purpose
Bundle multiple Azure assessment tools into a single, portable runner. Output unified JSON + HTML/Markdown reports.

## Query format
- ARG queries live in `queries/` as JSON (not .kql files)
- Every query MUST return a `compliant` column (boolean)
- See alz-graph-queries repo for query schema reference

## Branch protection
- Signed commits NOT required (breaks Dependabot and GitHub API commits)
- 0 required reviewers (solo-maintained)
- enforce_admins = true, linear history, no force push
- Required status checks: CodeQL Analyze (actions), CodeQL Analyze (python), Validate Queries

## CodeQL policy
- This repo has Python + GitHub Actions workflows — both are scanned
- Actions scanning covers workflow injection risks
- Python scanning covers the tool wrappers and orchestrator

## SHA-pinning
- All GitHub Actions MUST use SHA-pinned versions, not tags
- Example: `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2`

## Permissions
- Azure tools need Reader only — NO write permissions
- See PERMISSIONS.md for full breakdown per tool

## Documentation rules — ALWAYS required

Every PR that changes code, queries, or configuration MUST include a docs update in the same commit:

- ✅ `README.md` — update feature list, supported tools, permissions summary if changed
- ✅ `PERMISSIONS.md` — update if new Azure/Graph/GitHub API scopes are added
- ✅ `CHANGELOG.md` — add an entry for every user-visible change (feature, fix, breaking)
- ✅ Inline comments in new PowerShell modules if the logic is non-obvious

**No code PR merges without a matching docs update. This is not optional.**

## Issue conventions

- ✅ Every new issue MUST have the `squad` label — this is how Ralph (squad watch) picks it up for dispatch
- ✅ The auto-label-issues workflow adds `squad` automatically on open — never remove it
- ✅ Use labels `enhancement`, `bug`, `documentation` alongside `squad` to signal priority and type
- ✅ Issue titles must follow: `feat:`, `fix:`, `docs:`, `chore:` prefix
