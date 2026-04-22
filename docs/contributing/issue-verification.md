# Issue Resolution Verification

Praxis is the validation layer that closes a long-standing gap: when a PR
merges with `Closes #N` in its body, GitHub auto-closes the issue without
ever re-running the original repro. A flaky merge or a partial fix would
silently close the issue and the regression would sneak back in unnoticed.

The `issue-resolution-verify.yml` workflow plugs that gap by re-running the
`## Repro` block from each closed issue's body on a clean runner the moment
the closing PR merges.

## How it works

1. Trigger: `pull_request` event with type `closed`, gated on
   `github.event.pull_request.merged == true`.
2. Resolve every issue the PR closes via the `closingIssuesReferences`
   GraphQL field on the merged PR.
3. For each issue, parse the body for a `## Repro` (or `## Reproduction`)
   heading followed by a fenced code block.
4. Execute the block according to its declared type (see below).
5. On PASS: leave the issue closed and post a confirmation comment.
6. On FAIL: reopen the issue, label it `verification-failed`, post the
   sanitized tail of the output, and open a tracker issue assigned to the
   PR author.
7. On a missing block: if the issue is labelled `bug`, fail-soft reopen
   with an explanation. Other label sets (enhancement, docs, chore, epic,
   defer-post-window) are skipped silently.

## Repro block formats

The first line of the fenced block declares the type. Exactly one type per
block. Whitespace around the colon is tolerated.

### `pester:`

```
pester: <Pester FullNameFilter pattern>
```

The runner executes:

```pwsh
Invoke-Pester -Path .\tests -FullNameFilter '<pattern>' -CI -PassThru
```

PASS when `FailedCount == 0` and `PassedCount >= 1`. Use this for any bug
that has (or should have) a regression test.

### `shell:`

```
shell: <single-line pwsh command>
```

The runner spawns `pwsh -NoProfile -NonInteractive -Command <command>` with
a 300-second hard timeout. PASS when exit code is 0. Use this for bugs that
are easier to reproduce by invoking the orchestrator or a script directly.

### `gh:`

```
gh: <single-line gh CLI call>
expect: <optional regex matched against stdout>
```

The runner executes the `gh` CLI call (the leading `gh ` is added if you
omit it). PASS requires exit code 0 AND, if `expect:` is present, the
regex matching anywhere in stdout. Use this for bugs that manifest in the
GitHub API surface (workflow definitions, label states, branch protection).

### `manual:`

```
manual: <free text describing what to verify by hand>
```

No automated check. Praxis labels the issue `verify-manual` and posts an
informational comment. Use this only when the verification genuinely
cannot be automated (visual rendering, multi-region capacity probes,
human review of generated content).

## Labels in play

- `verify-manual` - Praxis saw a `manual:` block and is deferring to a
  human. The issue stays closed but the label flags it for the next
  maintainer review pass.
- `verification-failed` - the repro re-ran and failed. Praxis reopened the
  issue and opened a tracker assigned to the PR author. CI watchdogs
  (Vigil) route these to the right specialist (Hunter for code regressions,
  Helix for test regressions, Orca for OS-specific regressions).

## Authoring tips

- Keep the repro deterministic. Network calls, region-specific quotas, and
  current-time math will produce flaky verifications.
- Keep secrets out. The runner sanitizes output via the same rules used by
  `modules/shared/Sanitize.ps1`, but defence in depth starts with not
  pasting tokens into the issue body in the first place.
- Prefer `pester:` when a regression test exists - it gives Praxis a
  single, fast, well-scoped signal.
- For a `shell:` repro, exit non-zero on failure. `Set-StrictMode -Version
  Latest` plus `$ErrorActionPreference = 'Stop'` gives you that for free.
- For a `gh:` repro, narrow the `expect:` regex to the exact field that
  asserts the fix - matching the whole payload makes the gate brittle.

## Test coverage

The parsing, execution, and sanitization logic lives in
`.github/scripts/Verify-IssueRepro.ps1` and is exercised by
`tests/workflows/IssueResolutionVerify.Tests.ps1`. Any change to the parser
or the runner must keep that suite green.
