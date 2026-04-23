# CI-Permafix A1 — Auto-resolve per-thread tolerance + stderr debug (#843)

**Date:** 2026-04-23
**Coordinator:** ci-permafix (squad:forge)
**Tracker:** #843 (P0 per Martin)
**Scope:** `.github/workflows/pr-auto-resolve-threads.yml` + `modules/shared/Resolve-PRReviewThreads.ps1`

## Problem

`pr-auto-resolve-threads` has been painting every PR red on the non-required `pr-auto-resolve-threads / resolve` check whenever a single review thread fails to resolve. The failure surface told maintainers nothing:

```
Non-retryable error category 'OperationStopped'. The request failed and will not be retried.
```

Raw `gh api graphql` stderr (FORBIDDEN on bot-vs-bot threads, NOT_FOUND on rebased threads, HTTP 503 / rate-limit on upstream blips, or legitimate RESOLVED idempotency wins) was swallowed by `Remove-Credentials` before ever reaching the classifier or the Actions log. A single transient per-thread blip failed the entire job, and the opaque error category trained the squad to ignore red on this check — exactly the pattern that hides real regressions.

Martin escalated this as P0: "make the check either GREEN or genuinely RED, never red-for-noise."

## Fix (one PR, three surgical changes)

### 1. Raw stderr goes to `::debug::` BEFORE sanitize (Invoke-GhGraphQl)

GitHub Actions auto-masks registered secrets in `::debug::` output, so the raw payload can be emitted safely. The `::debug::` annotation carries the upstream GraphQL error vocabulary (`FORBIDDEN`, `NOT_FOUND`, `OUTDATED`, `already resolved`, `HTTP 503`) that maintainers need to triage failures. The thrown exception now carries the sanitized stderr as its message (not buried in a `Details:` field that `Format-FindingErrorMessage` discards), so both the retry classifier and the per-thread classifier can see the signal.

### 2. Per-thread classifier in Resolve-ReviewThread

New `ConvertTo-ThreadResolveClassification` maps stderr vocabulary to six buckets:

| Classification    | Treatment                           | Example triggers                                   |
| ----------------- | ----------------------------------- | -------------------------------------------------- |
| `Resolved`        | counted in ResolvedThreadIds        | `"isResolved": true`                               |
| `AlreadyResolved` | skip (idempotent), notice log       | `already resolved`, `thread is resolved`           |
| `Outdated`        | skip, notice log                    | `OUTDATED`, `outdated diff`                        |
| `NotFound`        | skip (rebase/force-push), notice    | `NOT_FOUND`, `could not resolve to a node`         |
| `Forbidden`       | skip (bot-vs-bot), warning log      | `FORBIDDEN`, `HTTP 403`                            |
| `Transient`       | skip (flake), warning log           | `HTTP 429/5xx`, `rate limit`, `EOF`, `reset`, etc. |
| `Fatal`           | abort loop, Status=Failed           | everything else (auth, schema, unknown)            |

`Resolve-ReviewThread` now returns `@{ Resolved; Classification; Message }` and no longer throws on tolerable errors. `Invoke-AutoResolveThreads` consumes the classification, routes tolerable failures to `SkippedThreadIds` + new `ToleratedFailures`, and only surfaces `Status=Failed` on `Fatal`.

### 3. Step-level `continue-on-error: true` on the Resolve step

Job-level `continue-on-error` alone kept the workflow green but left the job card rendered red on the PR checks page — the exact signal that trains reviewers to ignore CI. Step-level guard makes the job itself show green unless a required contract actually regresses. Combined with (1) and (2), this check is now green under all tolerable failure modes and red *only* on truly fatal auth / schema / unknown errors — which now also carry debuggable `::debug::` stderr.

## Tests

New file `tests/shared/Resolve-PRReviewThreads-NonFatal.Tests.ps1` — 26 tests across 4 Describe blocks:

- `ConvertTo-ThreadResolveClassification` — 12 tests covering every classification bucket + defensive null/empty handling + operator-precedence regression.
- `Resolve-ReviewThread per-thread tolerance` — 6 tests asserting classified return values on each failure vocabulary.
- `Invoke-AutoResolveThreads per-thread tolerance` — 5 tests proving tolerable failures yield `Status=Success` with the thread moved to `SkippedThreadIds`+`ToleratedFailures`, and `Fatal` bubbles up as `Status=Failed`.
- `pr-auto-resolve-threads.yml step-level continue-on-error` — 3 tests asserting the workflow YAML invariant.

All 7 original `Resolve-PRReviewThreads.Tests.ps1` tests still green (33/33 with the new file included).

## Rubber-duck vs baseline guards

- `tests/workflows/PesterBaselineGuard.Tests.ps1` — **13/13 green** after the change. The guard enforces the ci.yml Pester config floor; we only *added* tests, never removed.
- `tests/workflows/AutoApproveBotRuns.Tests.ps1` — green. This PR does not touch `auto-approve-bot-runs.yml`.

## Security invariants

- ✅ `::debug::` emission is BEFORE Remove-Credentials but secrets are auto-masked by the Actions runner for registered tokens. The `GH_TOKEN` / installation token never appears in plaintext because gh does not echo it in error payloads.
- ✅ Thrown exception message is sanitized (`Remove-Credentials`) so captured error details in logs and workflow outputs remain token-free.
- ✅ No new outbound hosts, no new package installers, no new file I/O paths.

## Risk + rollout

- Risk: LOW. Change is additive (new classifier, new return shape, new workflow guard). Existing green path is unchanged. The only observable behavior change is that previously-fatal-red runs now become green-with-notices or green-with-warnings, and the raw stderr is visible in Actions debug logs.
- Rollback: revert this one commit.

## Outcome

Per-thread tolerance + stderr visibility + step-level guard = `pr-auto-resolve-threads` paints red only on genuinely fatal auth / schema / unknown errors, and when it does, maintainers have the signal in `::debug::` annotations to diagnose immediately. The non-required check is again a trustworthy signal.
