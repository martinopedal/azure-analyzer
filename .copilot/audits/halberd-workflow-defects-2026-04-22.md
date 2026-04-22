# Halberd workflow defect inventory — 2026-04-22

Author: Halberd (workflow defect generalist)
Scope: `.github/workflows/*.yml`

## Heatmap

| Category | Status | Count | Notes |
|---|---|---|---|
| CAT-A SHA-pin violations | CLEAN | 0 | All `uses:` are 40-char SHA + `# vN.N.N` comment |
| CAT-B Missing retries | TBD | TBD | Inventory in next pass; existing tests/workflows/RetryWrapping.Tests.ps1 already enforces |
| CAT-C Missing permissions | CLEAN | 0 | All workflows declare permissions either at top-level or job-level (codeql.yml uses job-level which is more restrictive) |
| CAT-D Stuck approval gates | DEFER | n/a | Owned by Vega |
| CAT-E Missing concurrency | DEFECT | 8 | bicep-build, ci, codeql, docs-check, markdown-link-check, pr-review-gate, stub-deadline-check, copilot-agent-pr-review |
| CAT-F Missing timeouts | DEFECT | 22 | Nearly every job lacks `timeout-minutes:`. See breakdown below. |
| CAT-G Workflow injection | CLEAN | 0 | No raw `${{ github.event.*.title|body|head_ref }}` interpolated into `run:` blocks |
| CAT-H Hardcoded secrets in run output | CLEAN | 0 | No `echo $TOKEN` patterns |
| CAT-I Stale pinned actions | TBD | TBD | Defer to chore PR after CAT-F/E/B sweeps |
| CAT-J Failure tracker auto-open | OK | n/a | `ci-failure-watchdog.yml` covers this |
| CAT-K Pester strategy gaps | DEFER | n/a | Coordinate with Helix |

## CAT-F detailed list (jobs missing `timeout-minutes:`)

| Workflow | Jobs missing | Proposed timeout |
|---|---|---|
| alz-queries-drift-check.yml | drift-check | 15 |
| auto-label-issues.yml | label | 5 |
| bicep-build.yml | bicep-build | 15 |
| ci-failure-watchdog.yml | triage-failure | 10 |
| ci-health-digest.yml | digest | 15 |
| ci.yml | test, verify-install-manifest, generate-sbom | 45, 15, 20 |
| codeql.yml | analyze | 30 |
| copilot-agent-pr-review.yml | request-copilot-review | 5 |
| docs-check.yml | docs-required, tool-catalog-fresh, permissions-pages-fresh | 10, 10, 10 |
| markdown-link-check.yml | markdown-link-check | 15 |
| pr-auto-rebase.yml | enumerate, rebase | 10, 20 |
| pr-auto-rerun-on-push.yml | rerun-failed-checks | 10 |
| pr-auto-resolve-threads.yml | auto-resolve | 10 |
| pr-review-gate.yml | review-gate | 10 |
| release.yml | release | 20 |
| squad-heartbeat.yml | heartbeat | 15 |
| squad-issue-assign.yml | assign-work | 10 |
| squad-triage.yml | triage | 10 |
| stub-deadline-check.yml | check-stub-deadline | 5 |
| sync-squad-labels.yml | sync-labels | 10 |
| tool-auto-update.yml | bump | 15 |

Already covered: pr-advisory-gate (advisory-gate), scheduled-scan (scan + report).

## CAT-E detailed list (PR-triggered without concurrency cancel-in-progress)

| Workflow | Triggers | Notes |
|---|---|---|
| bicep-build.yml | push, pull_request, workflow_dispatch | Add concurrency keyed on ref |
| ci.yml | push, pull_request, workflow_dispatch | Add concurrency; preserve push to main (no cancel) |
| codeql.yml | push, pull_request, schedule, workflow_dispatch | Add concurrency keyed on ref |
| copilot-agent-pr-review.yml | pull_request_target | Add concurrency keyed on PR number |
| docs-check.yml | pull_request | Add concurrency keyed on PR number |
| markdown-link-check.yml | pull_request, schedule, workflow_dispatch | Add concurrency keyed on ref |
| pr-review-gate.yml | pull_request_review, pull_request_review_comment | Add concurrency keyed on PR number |
| stub-deadline-check.yml | push, pull_request | Add concurrency keyed on ref |

## Ship plan

1. PR 1 — `fix(ci): add timeout-minutes to every job` (CAT-F)
2. PR 2 — `fix(ci): add concurrency cancel-in-progress to PR-triggered workflows` (CAT-E)
3. PR 3 — CAT-B retry sweep after re-running RetryWrapping baseline
4. PR 4 — CAT-I stale SHA refresh

Each PR ships a Pester convention test under `tests/workflows/` to lock the rule.
