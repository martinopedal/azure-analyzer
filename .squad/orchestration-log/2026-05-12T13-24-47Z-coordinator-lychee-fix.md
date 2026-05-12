# Lychee broken-link fix — PR #1053 follow-up

**Date:** 2026-05-12 13:24:47 UTC  
**Agent:** Coordinator (manual fix)  
**Status:** PR #1053 updated; lychee re-queued; auto-merge ON

## Headline

Fixed 404 in PR #1053 by correcting a stale discussion link to the actual PSGallery research issue.

## Context

PR #1053 (Sage docs-voice install + history log) failed lychee check. The `.squad/orchestration-log/2026-05-12T13-00-13Z-forge-gpg-fix.md` file referenced `/discussions/1049` (which is a PR, not a discussion). Lychee correctly flagged 404. The correct reference is issue #963 (where Sage's PSGallery research brief actually lives).

## Action

Updated `.squad/orchestration-log/2026-05-12T13-00-13Z-forge-gpg-fix.md` line 45:
- Before: `https://github.com/martinopedal/azure-analyzer/discussions/1049`
- After: `https://github.com/martinopedal/azure-analyzer/issues/963`
- Description: "Sage PSGallery research" (unchanged; still accurate)

Commit: `846aaac`  
Branch: `chore/docs-voice-profile`

## Files touched

- `.squad/orchestration-log/2026-05-12T13-00-13Z-forge-gpg-fix.md` (1 line corrected)

## Cross-refs

- **PR:** [#1053](https://github.com/martinopedal/azure-analyzer/pull/1053)
- **Orchestration log:** `.squad/orchestration-log/2026-05-12T13-00-13Z-forge-gpg-fix.md`
- **Lychee re-queue:** Run 25737364997 (re-triggered post-fix; status=completed, conclusion=success)
- **Source issue:** [#963](https://github.com/martinopedal/azure-analyzer/issues/963) (Sage PSGallery research)

## PR state after push

- Status: OPEN
- mergeStateStatus: BEHIND (will auto-merge when main catches up)
- autoMergeRequest: ON (SQUASH)
- Required check `Analyze (actions)`: IN_PROGRESS (re-triggered by lychee re-queue)
