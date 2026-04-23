# Copilot review thread resolution

## Decision: Agent-self-resolve

Effective with #604, the Copilot SWE agent that authors a pull request is
responsible for resolving its own review threads as part of the PR-completion
contract. There is no longer a standalone GitHub Actions workflow that
auto-resolves threads on behalf of the agent.

## Background

PR #487 (`fb7fa1f`) shipped an interim hotfix that made the
`pr-auto-resolve-threads.yml` workflow non-fatal when the GraphQL
`resolveReviewThread` mutation returned `FORBIDDEN` on bot-vs-bot resolution
attempts. The hotfix masked the symptom; the root cause was unaddressed.

Quoting #604 verbatim:

> GitHub's `resolveReviewThread` mutation requires the caller to either author
> the thread or have user-level write access. The default `GITHUB_TOKEN`
> (acting as `github-actions[bot]`) cannot reliably resolve threads opened by
> `copilot-pr-reviewer[bot]` / `copilot-swe-agent[bot]` regardless of
> `permissions: pull-requests: write`. Behavior is inconsistent: succeeded on
> PR #481's batch of 17 threads, FORBIDDEN elsewhere.

Issue #604 listed three options:

1. Dedicated GitHub App token (`RESOLVE_THREADS_TOKEN` secret) with
   `pull_requests:write` issued to a non-bot identity.
2. Trigger the workflow as the PR author via `workflow_dispatch` from the
   agent's own job.
3. Remove the workflow and rely on the Copilot SWE agent to resolve its own
   threads as part of its PR-completion contract.

## Why we chose Option 2 (agent-self-resolve)

The maintainer chose the agent-self-resolve path (option 3 in the issue list,
recorded here as the project decision). Reasons:

- No GitHub App provisioning overhead. We do not need to create, install, and
  rotate credentials for a separate identity just to satisfy GitHub's
  bot-vs-bot ACL on a single GraphQL mutation.
- The Copilot SWE agent already authors the PR and the addressing commits, so
  it has the natural authority and context to decide which threads are
  addressed, which are rejected, and what the reply text should be.
- It collapses two systems (workflow plus author) into one (author only),
  which is easier to reason about when a thread is left open.
- The agent owns its PRs end-to-end, which matches how the rest of the squad
  loop already works (build, review, fix, re-gate, CI, merge).
- The `pr-advisory-gate.yml` workflow and `Get-CopilotReviewFindings.ps1`
  still consume `modules/shared/Resolve-PRReviewThreads.ps1` for thread
  enumeration and reply posting, so the helper module stays. Only the
  standalone auto-resolve workflow was removed.

## Contract for the Copilot SWE agent

When a Copilot SWE agent owns a PR, it MUST:

1. For every review thread that the agent has addressed with a code change in
   the same PR, call the GraphQL `resolveReviewThread` mutation on that
   thread. The agent is the thread author by virtue of being the PR author
   when the thread is on its own code, so the mutation is authorized.
2. Post a short reply on the thread linking the addressing commit SHA before
   resolving it.
3. For threads where the agent disagrees with the reviewer, post a
   justification comment (the multi-model rejection reasoning from the gate)
   but do NOT mark the thread resolved. A human reviewer adjudicates.
4. Process all review threads on the PR in a single PR-update cycle. Do not
   leave a partial pass where some threads are answered and others are
   silently skipped.
5. Treat unresolved-and-unanswered threads as a blocker for merge, identical
   to the rule in `.copilot/copilot-instructions.md` "Cloud Agent PR Review"
   loop.

## Failure mode

If the agent forgets to call `resolveReviewThread`, the threads stay open and
remain visible in the PR review tab. Two recovery paths:

- A human (maintainer or reviewer) can resolve the threads manually from the
  GitHub UI.
- The issue can be reopened and the agent can be asked to do another
  PR-update cycle.

There is no longer an automation backstop. This is the deliberate trade-off
of the agent-self-resolve choice.

## Migration

Existing PRs that already have stale unresolved threads from the period when
`pr-auto-resolve-threads.yml` was returning `FORBIDDEN` need a one-time human
pass. There is no automated migration script. Resolve them manually in the
GitHub UI as you encounter them.

## References

- Issue: #604 (this decision)
- Hotfix being properly resolved: #487 (`fb7fa1f`)
- Related throw-vs-exit-1 fix: #588
- Helper module that survives the workflow removal:
  `modules/shared/Resolve-PRReviewThreads.ps1` (consumed by
  `.github/workflows/pr-advisory-gate.yml` and
  `modules/shared/Get-CopilotReviewFindings.ps1`)
