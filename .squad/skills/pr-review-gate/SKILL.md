# PR Review Gate Skill

## Purpose

Ingest pull request review feedback, run a 3-model rubber-duck triage pattern, and emit a lockout-aware consensus plan.

## Inputs

- PR number
- Repo (`owner/name`)
- Optional model response payloads
- PR author agent login (for lockout)

## Pattern

1. **Capture**
   - Read `/pulls/{n}/reviews` and `/pulls/{n}/comments` via `gh api` with pagination.
2. **Prompt bundle**
   - Create per-model payload + structured prompt for:
     - `claude-opus-4.6`
     - `gpt-5.3-codex`
     - `goldeneye`
3. **Consensus merge**
   - Merge findings into:
     - Reviewer Verdict
     - Consensus Findings
     - Disputed Findings
     - Action Plan
   - Deterministic verdict precedence: `CHANGES_REQUESTED` > `COMMENTED` > `APPROVED`.
4. **Lockout enforcement**
   - PR author is locked out for revision if review gate rejects/flags changes.
   - Replacement owner must differ from locked-out author.
5. **Outputs**
   - Decision inbox doc: `.squad/decisions/inbox/{agent}-pr-{n}-review.md`
   - PR summary comment with verdict, lockout notice, and planned actions.

## Guardrails

- Never approve/dismiss reviews.
- Sanitize all persisted text with `Remove-Credentials`.
- Pass untrusted review content via environment variables, not command interpolation in workflows.
