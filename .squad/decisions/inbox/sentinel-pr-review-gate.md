# PR Review Gate Model Selection Decision

**Date:** 2026-04-17  
**Agent:** Sentinel (Security & Recommendations Analyst)  
**Status:** ✅ Approved for implementation

## Decision

For PR review-gate triage, use three diverse models:

- `claude-opus-4.6` (premium Claude reasoning)
- `gpt-5.3-codex` (code-focused OpenAI/codex perspective)
- `goldeneye` (architectural diversity and independent critique)

## Rationale

Single-model review under-captures edge cases in workflow security, lockout governance, and consensus-merging logic. This trio gives overlap on core correctness while preserving disagreement signal for disputed findings. The model mix also avoids homogeneous failure modes during high-risk review states such as `CHANGES_REQUESTED` and bot-authored review bursts.

## Operating Rule

1. Ingest PR reviews and line comments.
2. Generate model-specific prompt bundle and payload files.
3. Merge three model responses into deterministic consensus.
4. Record lockout notice with a replacement revision owner that is not the PR author.
5. Post PR summary comment linking the gate output path.

## Security Constraint

The gate must not approve or dismiss reviews itself. It is read + comment + plan-write only.
