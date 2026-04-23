### 2026-04-23T23:05Z: Session 16 checkpoint — CI stabilization sprint

**By:** Squad Coordinator (requested by Martin Opedal)

## What landed this session
- PR #947 MERGED — watchdog advisory filter (7 issues auto-closed: #908 #913 #916 #920 #921 #923 #929)
- PR #940 MERGED — Pester bootstrap fix (SampleDrift syntax + stream-6)
- PR #931 MERGED — module import regression gate
- PR #944 rebased + auto-merge armed (watchdog schedule refactor)
- PR #914 rebased + auto-merge armed (closes-link bot bypass)
- PR #912 fresh implementation + auto-merge armed (watchdog 24h coalesce)
- PR #950 opened + auto-merge armed (phantom envelope M1+M3 keystone — 2706 tests pass)
- PR #952 opened + auto-merge armed (DocsCheck test fix H4/M4 — 9 tests, closes 8 ci-failure issues)
- PRs #928 + #949 closed (corrupt commits, unsalvageable)
- Issues #915 #930 closed (already resolved in v1.1.3)
- 9 ci-failure issues batch-closed by gap audit (#933-#936, #939, #942-#943, #945-#946)

## RCA completed (3-model + 24h audit)
- rca-drift-sonnet.md (10.4KB) — dual-track: advisory filter + semantic HTML
- rca-drift-opus.md (8.3KB) — bootstrap crash + mixed newlines
- rca-drift-codex.md (3.8KB) — CRLF/LF platform variance
- audit-24h-ci.md (37.6KB) — 5 failure modes (M1-M5), per-PR history, implementation specs
- lead-issue-gap-audit.md — exhaustive issue-vs-PR coverage map

## Root causes identified and fixed
- M1: New-WrapperEnvelope.ps1 phantom output on dot-source → PR #950 (function definition)
- M2: SampleDrift cross-platform newline mismatch → forge-sampledrift-fix agent (still running)
- M3: Errors.Regression529 child-process crash → fixed by PR #950 (same root cause as M1)
- M4: DocsCheck test missing docs/design assertion → PR #952
- M5: WatchdogWatchlist stale entry → fixed by PR #944

## Workflow approval gate (unresolved)
- Root cause: release-please uses GITHUB_TOKEN → PRs authored by github-actions[bot] → not a collaborator → action_required on public repo
- Bot accounts cannot be invited as collaborators (API returns 404 "not a user")
- Fix: create RELEASE_PLEASE_TOKEN PAT secret, change release.yml line 43
- Settings UI fork-PR setting does NOT help — this is in-repo branches from bot actors

## Directives captured (6)
- No main pushes, no duplicate PRs, always auto-merge squash
- CI RCA required before further work on repeat failures
- No workflow approvals for squad/copilot/Martin
- Always use high reasoning for all models

## Remaining open (5 issues, 5 PRs auto-merging)
- Issues: #907 (wrapper contract, partial), #910 (closes by #914), #926 (FixtureMode), #938 (gate), #506 (deferred)
- PRs auto-merging: #950 #952 #944 #914 #912

## Phase H plan (next session)
- H1: Wrapper envelope contract across 37 wrappers (#907) — codex model
- H2: FixtureMode E2E flag (#926) — depends on H1
- H3: Auto-approve gate replacement (#938) — depends on #944
- H4: DocsCheck test fix (M4) — DONE (PR #952)
- H5: Test isolation (#746) — depends on H1
- Release-please PAT fix — manual step for Martin

## Recommendation
Start new session now. All PRs have auto-merge armed. They'll merge automatically as CI passes. The forge-sampledrift-fix agent is still running but will complete independently. New session starts clean with Phase H.
