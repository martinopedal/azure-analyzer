# Copilot Instructions - azure-analyzer

## Development Process

All code changes follow this pipeline:

1. **Build** - implement on a feature branch, run tests locally
2. **Review Gate** - 3-model code review (Opus 4.7 + Goldeneye + GPT-5.3-codex)
   - Gate-pass rules are defined in "Review Severity Taxonomy" below (this supersedes the older "all 3 must APPROVE" rule)
   - Parse-check all .ps1 files, verify no ?. syntax, check error handling
3. **Fix** - address all findings from reviewers
4. **Re-gate** - re-run review with the models that rejected, verify fixes
5. **Final Review Gate** - if re-gate passes, proceed. If not, loop back to Fix
6. **CI** - all GitHub Actions must pass (`Analyze (actions)`)
7. **Merge** - squash merge to main, delete feature branch

## Automated Review Ingestion

When ANY squad / bot PR is opened, marked ready_for_review, or synchronized, the `pr-advisory-gate.yml` workflow runs the universal advisory gate (#109). It posts or updates a single comment on the PR under the `<!-- squad-advisory -->` marker, with findings tagged per the severity taxonomy below. Untagged findings are auto-tagged `[correctness]` (fail-safe). The advisory gate is **non-blocking**, it primes the human / Copilot reviewer with context but never gates merge. Disable repo-wide via the `SQUAD_ADVISORY_GATE=0` repo variable.

When a PR gets `CHANGES_REQUESTED`, or when Copilot/human review comments are added, the `pr-review-gate.yml` workflow triggers automatically. It ingests PR reviews/comments, builds a 3-model triage bundle (Claude premium + GPT codex + Goldeneye), writes the consensus plan to `.squad/decisions/inbox/`, and posts a PR summary comment with ownership and next actions. Reviewer Rejection Lockout is automatic, the rejected PR author agent is mechanically locked out from doing the revision in that gate cycle, and the consensus must name a different revision owner.

When a revision agent pushes a fix commit, the `pr-auto-resolve-threads.yml` workflow runs (on `pull_request_target` synchronize / `pull_request_review` events, with a fork-skip guard) and calls `modules/shared/Resolve-PRReviewThreads.ps1`. For every unresolved review thread on the PR, it checks whether commits added AFTER the thread was created modified the same file at an overlapping line range. If yes, the thread is resolved via the `resolveReviewThread` GraphQL mutation and a short reply is posted on the thread linking the addressing commit SHA. Threads the new commits did NOT touch stay open, and the reviewer decides. Disable repo-wide via the `SQUAD_AUTO_RESOLVE_THREADS=0` repo variable.

## Frontier Model Roster (strict, no exceptions)

The 3-model gate, all squad sub-agent spawns, and every rubber-duck call MUST use frontier models only. Non-frontier models silently degrade review quality and are forbidden for any non-mechanical task in this repo.

| Role | Model | When to use |
|------|-------|-------------|
| Default coding / strategy | `claude-opus-4.7` | First choice for any squad agent, plan author, or code generation task. |
| Large-context | `claude-opus-4.6-1m` | Only when the task genuinely needs >200k tokens of context (entire codebase audits, multi-file refactors). Do not use for general coding. |
| Latest codex (coding) | `gpt-5.3-codex` | Code-heavy reviews, code generation when diversity vs Claude is needed. |
| Latest GPT (general) | `gpt-5.4` | Non-coding analysis, plan critique, general reasoning when diversity is needed. |
| Code review (architectural diversity) | `goldeneye` | Required third voice in the 3-model gate. |

**Forbidden for any non-mechanical task:**
- `claude-opus-4.6` base, `claude-opus-4.5`
- `claude-sonnet-*` (any version)
- `claude-haiku-*` (any version)
- `gpt-5-mini`, `gpt-5.4-mini`, `gpt-4.1` (cheap tier, never frontier)
- Any `*-codex` other than the latest (currently `gpt-5.3-codex`)

**Standard 3-model gate trio** (used by `Invoke-PRAdvisoryGate.ps1` and `Invoke-PRReviewGate.ps1`): `claude-opus-4.7` + `gpt-5.3-codex` + `goldeneye`. If any one is unavailable, the gate falls back to `claude-opus-4.6-1m` for that slot only, never to a sonnet or haiku.

When spawning sub-agents via the `task` tool, always pass the `model` parameter explicitly. Default omission has historically dropped agents onto sonnet, which violates this contract. When the selected model is unavailable, follow the Frontier Fallback Chain below. NEVER drop tier to sonnet/haiku/mini.

## Rate-Limit Retry + Frontier Fallback Chain

Every model-calling code path — both in-session agent spawns AND production model invocations (PR rubber-duck gate, copilot triage, etc.) — MUST implement explicit retry + model-swap fallback. Frontier-only, no exceptions.

### Fallback chain (in strict order)
1. `claude-opus-4.7`
2. `claude-opus-4.6-1m`
3. `gpt-5.4`
4. `gpt-5.3-codex`
5. `goldeneye`

If a chain entry is the same model that just failed, skip to the next. NEVER fall back to `claude-sonnet-*`, `claude-haiku-*`, `claude-opus-4.6` (base), `claude-opus-4.5`, `gpt-5-mini`, `gpt-5.4-mini`, `gpt-4.1`, or any non-latest codex.

### Per-model retry policy
- Max 3 retries before swapping models.
- Exponential backoff: `1s → 4s → 16s`, with 25% jitter on each delay.
- Retry-triggering signals (case-insensitive substring match on response body OR HTTP status):
  - HTTP 429, 503, 504
  - `rate_limit`, `quota_exceeded`, `overloaded`, `throttle`, `service_unavailable`, `temporarily_unavailable`
  - Network errors: socket timeout, connection reset, DNS failure
- Special case — `context_length_exceeded`: skip remaining retries on current model and IMMEDIATELY swap (more wait won't help).

### Per-call (overall) policy
- Max 5 model swaps before surfacing failure to the caller.
- Every swap MUST be logged to `.squad/decisions/inbox/{component}-fallback-{context}-{from}-to-{to}-{reason}.md` for durable audit.
- On chain exhaustion: fail closed. The gate posts a sticky PR comment `⚠️ Gate could not reach any frontier model (5 swaps × 3 retries exhausted). Manual review required.` and exits non-zero. Sub-agent spawns surface the error to the coordinator.
- Once a model returns a successful verdict in a given call, do NOT re-invoke it during subsequent retries for the same call/SHA.

### Three-model gate trio resolution
The standard rubber-duck trio is `claude-opus-4.7` + `gpt-5.3-codex` + `goldeneye`. If any trio member is rate-limited at gate start, substitute with the FIRST eligible chain entry NOT already in the trio (so a failed `gpt-5.3-codex` is replaced with `claude-opus-4.6-1m` first, then `gpt-5.4`). Maintain the "3 distinct frontier verdicts per SHA" invariant.

### Reuse `Invoke-WithRetry` for in-model retries
The per-model retry layer (3 attempts × exponential backoff) MUST use `modules/shared/Retry.ps1::Invoke-WithRetry` so the transient-pattern list and jitter implementation stay consistent across the codebase. The model-swap layer is a thin loop ON TOP of `Invoke-WithRetry`. Do not re-implement backoff.

## Copilot Review is Mandatory on Every PR

Every PR opened in this repo, by any author (squad agent, human, Dependabot, or external contributor), must receive a Copilot code review before merge. No exceptions, including doc-only and one-line PRs. The review is requested automatically by `copilot-agent-pr-review.yml` on PR open / reopen / ready-for-review, but the PR author is responsible for verifying the review actually arrived.

If the Copilot review has not posted within 5 minutes of the PR being marked ready, the author re-requests it manually:

```bash
gh pr edit <pr> --add-reviewer copilot-pull-request-reviewer
```

A PR with no Copilot review on the most recent commit cannot merge. The squad coordinator enforces this as a hard gate, even when the 3-model gate has approved.

## Comment Triage Loop (every Copilot finding)

Copilot review comments and inline suggestions are not advice, they are work items. The author treats every Copilot finding as input to a structured triage loop:

1. **Gather** - collect all Copilot review comments on the PR plus all comments on the linked issue (use `gh pr view <pr> --comments` and `gh api repos/{owner}/{repo}/pulls/{pr}/comments`). Do not cherry-pick, gather everything.

2. **Plan** - write a triage plan (in `plan.md` for the session, and reflected into the SQL `todos` table) listing each Copilot finding with one of: `accept`, `reject`, `defer`. Every `reject` must name the reason; every `defer` must link a follow-up issue.

3. **Rubber-duck until consensus** - run the plan through the 3-model gate (Opus 4.7 + Goldeneye + GPT-5.3-codex per the Frontier Model Roster, no sonnet/haiku). 2-of-3 consensus on each finding's disposition is required. If the models disagree, iterate the plan until 2-of-3 align. Record the consensus disposition next to each finding in the plan.

4. **Implement** - write code only after the plan reaches consensus. Each implementation commit references the Copilot finding it addresses (e.g. `Addresses Copilot finding: <quote first line>`).

5. **Re-gate on the diff** - re-run the 3-model gate against the new commit. Same pass criteria as the standard review gate (no `[blocker]` or `[correctness]` from any reviewer; 2-of-3 APPROVE).

6. **Reply on every Copilot thread** - either with the addressing commit SHA, or with the multi-model rejection justification. No Copilot thread may be left without an explicit reply. The `pr-auto-resolve-threads.yml` workflow resolves threads where the new commit touched the same lines, but the author is still responsible for the textual reply on rejections.

The Cloud Agent PR Review contract in `.squad/ceremonies.md` is the authoritative version of this loop for cloud-agent-authored PRs. The same loop applies to all PRs in this repo, regardless of author.

A PR cannot be marked ready for merge while any Copilot thread is unresolved or unanswered.

## Iterate Until Green — Resilience Contract

This directive applies to every squad agent, every cloud-agent (`copilot-swe-agent[bot]`) PR, every spawned helper via the `task` tool, and to the agent reading this file right now. Failure is the default state of a multi-system pipeline. The contract is not "succeed on the first try", it is **iterate until the PR is green AND merged**. Stopping at "blocked, needs maintainer" without exhausting the playbook below is itself a contract violation.

### Trigger
Any of the following are loop-entry events. None of them are terminal on their own:
- CI red (any required check failing — `Analyze (actions)`, `rubberduck-gate`, Docs Check, etc.)
- Pester red (local or in CI)
- Copilot review posted `CHANGES_REQUESTED` or any `[blocker]` / `[correctness]` finding
- 3-model gate rejection (any reviewer flagged `[blocker]` / `[correctness]`, or fewer than 2-of-3 APPROVE)
- Merge conflict against `origin/main`
- Rate-limit / model-unavailable error from any frontier model
- Flaky test (intermittent fail across runs of the same SHA)
- Branch state corrupted (lost commits, detached HEAD on a worktree, dirty index that cannot be reasoned about)

### Required loop (every failure)
1. **Read the failing logs.** For CI: `gh run view <run-id> --log-failed` (NOT `--log` — strip to the failed jobs). For Pester: re-run with `Invoke-Pester -Path <failing-test> -Output Detailed`. For Copilot: `gh pr view <pr> --comments` plus `gh api repos/{owner}/{repo}/pulls/{pr}/comments`. Do not guess at the failure mode from the workflow name alone.
2. **Diagnose the root cause.** Name it in plain prose in `plan.md` (one paragraph max) before touching code. "CI red" is not a root cause; "the new normalizer emits a null `EntityId` for findings whose raw payload omits `resourceId`" is.
3. **Fix at the root cause.** Patching the symptom (e.g. silencing a test, lowering a threshold, retry-loop around a real bug) is forbidden unless the symptom IS the contract (e.g. a true flake — see playbook).
4. **Push.** `git push` the fix to the same PR branch. Do not open a parallel PR.
5. **Wait + re-verify.** `gh pr checks <pr> --watch` for CI; re-read Copilot comments for review; re-run Pester locally for test changes. Do not assume the fix worked.
6. **Repeat** from step 1 against the next failure surface. Loop terminates only when the PR is green AND squash-merged.

### Per-failure-type playbook
- **CI red** → `gh run view <run-id> --log-failed`, identify the failing step, fix root cause in code (NOT in the workflow unless the workflow itself is broken), push, `gh pr checks <pr> --watch`.
- **Pester red** → run the failing file in isolation with `-Output Detailed`, fix the code or the test (whichever is wrong — both are valid outcomes), re-run the full suite locally before pushing, never push a red Pester suite.
- **Copilot rejection** → enter the Comment Triage Loop (see section above) for every finding, rubber-duck through the 3-model gate, implement consensus dispositions, reply on every thread with addressing SHA or multi-model rejection justification, do not mark ready until all threads are resolved or answered.
- **Rate-limit / model unavailable** → walk the Frontier Fallback Chain (see "Rate-Limit Retry + Frontier Fallback Chain" above): `claude-opus-4.7` → `claude-opus-4.6-1m` → `gpt-5.4` → `gpt-5.3-codex` → `goldeneye`. NEVER fall back to sonnet, haiku, mini, `gpt-4.1`, or any non-latest codex. Log every swap to `.squad/decisions/inbox/`.
- **Merge conflict** → first check whether the `PR Auto-Rebase Conflicts` workflow (`.github/workflows/pr-auto-rebase.yml`) has already applied a union-merge to additive files (CHANGELOG, manifest, README, docs/). If it posted a "Manual rebase required" comment, the conflict is genuine logic: `git fetch origin main && git rebase origin/main`, resolve in the worktree, re-run Pester to confirm semantic merge, `git push --force-with-lease` (NEVER plain `--force`). Trigger a sweep manually via `gh workflow run pr-auto-rebase.yml` if `main` advanced and your PR has not yet been re-evaluated.
- **Branch corrupted** → create a fresh worktree from `origin/main` (`git worktree add C:\git\worktrees\<name>-recover origin/main`), cherry-pick the clean commits across, push to a new branch, open a replacement PR that closes the corrupted one. Do NOT `git reset --hard` or `git clean -fd` on the original worktree.
- **Flaky test** → re-run the suite 3x. If it passes 3-for-3, the original was a transient. If it fails 1+ times out of 3, the test IS flaky and the flake itself is the bug — fix the race / ordering / fixture-pollution / time-dependency. Marking a test `-Skip` or `-Pending` to ship green is forbidden.

### Escalation rule
Escalation to a human maintainer is permitted **only after at least 3 distinct strategies have been tried and documented**. "Distinct" means addressing different hypothesized root causes, not 3 retries of the same fix. Before escalating:
1. Write a short analysis in the PR (sticky comment, ideally also mirrored to a `squad` issue) listing each strategy attempted, the observed result, and why the next obvious strategy is also expected to fail.
2. Tag the maintainer in that comment with the analysis inline. Do NOT escalate by closing the PR or by silently abandoning the branch.
3. The 3-strategy threshold applies per failure mode, not per PR. A new failure that emerges after a fix landed counts as a fresh loop.

### Hard rule
**A PR is "done" only when it is green AND merged.** "Tests are green locally", "Copilot has no further comments", "I think CI will pass" are not done. Replies of the form "blocked, needs maintainer to look" without the 3-strategy analysis above are a contract violation and the agent must resume the loop.

### Workflow-layer auto-retry (engages BEFORE this loop)
As of repo directive 2026-04-22T23:26:00Z, the `.github/workflows/pr-auto-rerun-on-push.yml` workflow auto-reruns failed/cancelled checks on every push to a PR branch matching `squad/*`, `copilot/*`, `fix/*`, `ci/*`, or `feat/*`. It waits 30 seconds after the push for checks to register, then calls `gh run rerun <id> --failed` (only failed jobs, cost-optimized) on each red check and posts a single summary comment. This means **the iterate-until-green loop above only engages on the SECOND failure**: one transient-flake retry has already happened at the workflow layer, free of charge. If a check is still red after the auto-rerun, that is a real signal and the agent enters the loop above starting at step 1 (read the failing logs). Do not manually rerun checks on these branches; the workflow has already done it. Do not rely on the auto-retry to mask a real bug; if the same check fails twice on the same SHA, the bug is real.

### Bot-PR approval auto-bypass
GitHub gates workflow runs from outside-collaborator-classified actors (including `copilot-swe-agent[bot]`) behind a manual "Approve and run workflow" click. The required `Analyze (actions)` check then surfaces as `Expected -- Waiting for status to be reported` indefinitely, wedging the loop. The `.github/workflows/auto-approve-bot-runs.yml` workflow watches `workflow_run.requested` for the squad-critical workflows and, when the triggering actor matches the hard-coded trusted allow-list (`copilot-swe-agent[bot]`, `Copilot`, `copilot`, `dependabot[bot]`, `github-actions[bot]`, `martinopedal`), calls `/actions/runs/{id}/approve` automatically. An agent should never see the approval gate; if a run does get stuck on it (e.g. a new workflow not yet on the watch-list, or a new trusted bot identity), the fix is to extend the watch-list or allow-list in that workflow file, not to ask a maintainer to click through. Invariants are locked by `tests/workflows/AutoApproveBotRuns.Tests.ps1` (allow-list shape, permission scope, trigger surface).
### Systemic step-level retry invariant (every workflow, every network step)
Independent of the PR-level auto-rerun above, every step that performs network I/O — PSGallery `Install-Module`, `gh api`/`gh run`/`gh pr`/`gh issue`, `git clone`, `Invoke-WebRequest`, `apt-get`, `curl`/`wget`, `winget install`, `pip install`, `npm install`, `az bicep ...` — MUST be wrapped in `nick-fields/retry@ad984534de44a9489a53aefd81eb77f87c70dc60` (v4.0.0, repo-pinned SHA) so transient hiccups self-heal at the step layer (3 attempts, 30-60s backoff). This is layer 1 of the resilience stack; the PR auto-rerun above is layer 2; the iterate-until-green loop is layer 3.

The only legal way to opt a network step out of `nick-fields/retry` is a `# no-retry: <reason>` comment on the line immediately above the step, justifying the opt-out. Acceptable reasons: non-idempotent side effects (e.g. `gh issue create` would open duplicates), the step has its own internal try/catch + dedup logic, or the step delegates to a vetted action that ships its own retry (e.g. `softprops/action-gh-release`, `github/codeql-action/*`, `actions/github-script` whose Octokit retries 5xx + 429).
`tests/workflows/RetryWrapping.Tests.ps1` enforces both halves of this invariant: every step doing network I/O is wrapped OR has a `# no-retry:` comment, AND every third-party `uses:` reference is SHA-pinned (40 hex). Adding a new workflow without satisfying these is a Pester failure on `main`. When bumping `nick-fields/retry`, update every workflow file and the SHA constant in `RetryWrapping.Tests.ps1` in the same PR.

### Cross-references
- "Rate-Limit Retry + Frontier Fallback Chain" (above) — the model-side resilience policy this section composes with.
- "Comment Triage Loop (every Copilot finding)" (above) — the structured loop for the Copilot-rejection failure mode.
- "Squad Pre-PR Self-Review (mandatory)" (below) — the Self-review block the loop produces before flipping draft → ready.

## Review Severity Taxonomy (#108)

PR review feedback (Copilot, the 3-model gate, or humans) currently mixes blockers, correctness defects, style preferences, and trivial nits, and the gate treats them all the same. To stop burning premium tokens on low-value feedback and to keep the Reviewer Rejection Lockout signal sharp, every reviewer finding **must** be tagged with one of four severity labels.

**Reviewers MUST prefix each finding with one of these tags:**

| Tag | Meaning | Examples | Gate behavior |
|-----|---------|----------|---------------|
| `[blocker]` | Data corruption, security vulnerability, breaks the build/tests, breaks production | "This will leak secrets to disk", "This panics on empty input", "Tests fail" | **Blocks merge.** Triggers full gate + Lockout. |
| `[correctness]` | Wrong behavior under expected input, missing error handling, contract violation, off-by-one | "Off-by-one in the loop bound", "Missing `$LASTEXITCODE` check", "This silently swallows the error" | **Blocks merge.** Triggers full gate + Lockout. |
| `[style]` | Formatting, naming, idiom, convention preference | "Use single quotes here", "Rename `$x` to `$result`", "PowerShell prefers `Get-Verb` style" | **Non-blocking.** Logged only; merge proceeds. |
| `[nit]` | Trivial polish, opinion, taste | "Typo in comment", "Could you reword this?", "I'd prefer two newlines here" | **Non-blocking.** Optional follow-up issue; merge proceeds. |

**Gate-pass criteria (severity-aware):**

This section supersedes the older "all 3 must APPROVE" rule referenced in the Development Process above.

A PR passes the review gate when **all** of the following hold (rules are ordered; rule 1 is an absolute veto). Each evaluation is keyed to the current PR head SHA — synchronize pushes restart the gate from scratch on the new SHA:

1. **No `[blocker]` or `[correctness]` finding from any reviewer.** Even one such finding fails the gate and activates Reviewer Rejection Lockout, regardless of how many reviewers approved overall.
2. **Either** of the following:
   - **2-of-3 APPROVE** from the 3-model gate (Opus 4.7 + Goldeneye + GPT codex) on the CURRENT head SHA, OR
   - **All `REQUEST_CHANGES` findings are `[style]` / `[nit]` only.**

Untagged findings are treated as `[correctness]` (fail-safe toward the gate) until a reviewer or follow-up classifier (#109) labels them.

**Reviewer instructions:**
- Prefix every finding line with the tag in square brackets, e.g. `[blocker] secrets written to logs in line 42`.
- One tag per finding. If a single comment contains multiple concerns, split them into separate tagged lines.
- When in doubt between two severities, pick the more severe one. Reviewers can downgrade in re-review; upgrading after merge is harder.
- `[style]` and `[nit]` are advice, not gates; authors may address them but are not required to before merge.

## Squad PRs - Draft by Default (#113)

Squad agents MUST open PRs as drafts to suppress reviewer-request emails during iteration:

```bash
gh pr create --draft --base main --head <branch> --title "..." --body "Closes #<n> ..."
```

Flip a draft PR to ready-for-review only when ALL of the following hold:
- CI is green
- The PR body contains a filled-in `## Self-review` section (#110)
- No unresolved advisory findings remain (#109)

The squad coordinator (or the PR author agent, after self-review) marks the PR ready via `gh pr ready <pr>`. Do not open non-draft PRs from agent workflows.

## Code Quality Rules

- PS 7.4+ only. No ?. null-conditional on variables
- $using: in ForEach-Object -Parallel must be copied to local vars before indexing
- All error paths must use Remove-Credentials for sanitization
- All CLI tool wrappers must check $LASTEXITCODE
- Use temp files for CLI JSON output, not stdout capture with 2>&1
- Every tool wrapper returns Status (Success/Failed/Skipped/PartialSuccess)
- Trivy: verify binary from official releases only (https://github.com/aquasecurity/trivy/releases)

## Documentation Rules

- Every PR that changes code must update README, CHANGELOG, PERMISSIONS.md as applicable
- Docs are rubber-ducked against actual code before merge
- No em dashes in any documentation

## Issue Verification Contract

Every closed issue must survive a re-run of its own repro. The
`issue-resolution-verify.yml` workflow (Praxis, #510) triggers on every
`pull_request` `closed` event with `merged == true`, walks the PR's
`closingIssuesReferences`, and re-executes the `## Repro` block from each
closed issue body on a clean runner.

- Block formats supported: `pester:`, `shell:`, `gh:` (with optional
  `expect:` regex), `manual:`. Full spec in
  `docs/contributing/issue-verification.md`.
- Bug issues without a `## Repro` block are fail-soft reopened by Praxis.
  Other label sets (enhancement, docs, chore, epic, defer-post-window)
  are skipped silently.
- On verified PASS: Praxis posts a confirmation comment and leaves the
  issue closed.
- On FAIL: Praxis reopens the issue, labels it `verification-failed`,
  posts the sanitized last 50 lines of output, and opens a tracker issue
  assigned to the PR author.
- Vigil routes `verification-failed` labels to the right specialist:
  Hunter for code regressions, Helix for test regressions, Orca for
  OS-specific regressions.
- The `bug.yml` issue template enforces a `## Repro` block at issue
  creation time. Manual-only checks are flagged with the `verify-manual`
  label so the next maintainer review pass picks them up.

## Squad Pre-PR Self-Review (mandatory)

Every squad agent MUST produce a `## Self-review` section in the PR body **before** calling `gh pr create`. This is a policy gate (CI enforcement deferred to follow-up): PRs without it should be amended immediately. Enforced manually by the Squad coordinator and PR reviewers until the CI check (#future) is built. The section compresses what changed, what could break, and what was tested so the reviewer (human or Copilot) does not start from zero.

**Required template (paste into PR body, fill all fields):**

```markdown
## Self-review

### Diff summary
- {bullet 1: what changed at a high level}
- {bullet 2}
- {bullet 3}

### Risks considered
- {risk 1}: {mitigation, or "accepted because ..."}
- {risk 2}: ...
- Out of scope on purpose: {what was deliberately NOT touched}

### Testing
- Ran: {test command(s) and pass/fail counts, e.g. `Invoke-Pester -Path .\tests -CI` → 542/542}
- Added: {new tests, or "none, doc/template-only change"}
- Skipped: {tests that don't apply}, {reason, or "n/a"}
```

**Rules:**
- Diff summary is **3 bullets max**, to force compression.
- Risks must include at least one "out of scope on purpose" line so reviewers know what the agent consciously left alone.
- Testing must name the actual command run, not "tests pass".
- Doc-only and template-only PRs still need this section. List "none, doc-only" under Added and the relevant test command (or `n/a`) under Ran.
- This applies to every squad member without exception, including the Lead.
