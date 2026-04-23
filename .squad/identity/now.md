# Current Focus — azure-analyzer

## Last session: 2026-04-23T23:05Z (CI stabilization sprint)

## Where we are
CI stabilization is 90% done. 3 PRs merged, 5 PRs auto-merging (950, 952, 944, 914, 912). 16+ issues closed. 3-model RCA + 38KB 24h audit completed. Phase H plan written.

## What's auto-merging right now (check first)
- PR #950 — phantom envelope fix (M1+M3 keystone, unblocks all PRs)
- PR #952 — DocsCheck test fix (H4/M4, closes 8 issues)
- PR #944 — watchdog schedule refactor (eliminates workflow_run trigger)
- PR #914 — closes-link bot bypass (closes #910)
- PR #912 — watchdog 24h coalesce (closes #908)

## Check these on catch-up
1. gh pr list --state open — how many of the 5 auto-merged?
2. gh issue list --state open — should be down to ~5 (907, 926, 938, 506, maybe 910)
3. gh run list --status action_required — Martin needs to set up PAT for release-please

## Next work (Phase H)
- H1: Wrapper envelope contract (#907) — 37 wrappers, use codex model. Depends on #950 merged.
- H2: FixtureMode E2E flag (#926) — depends on H1
- H3: Auto-approve gate (#938) — depends on #944
- H4: DONE (PR #952)
- H5: Test isolation (#746) — depends on H1
- Release-please PAT: Martin creates fine-grained PAT, adds as RELEASE_PLEASE_TOKEN secret, we change release.yml line 43

## Key files
- Plan: session-state plan.md (Phases A-J)
- 24h audit: .squad/decisions/inbox/audit-24h-ci.md (38KB, implementation specs)
- RCA: .squad/decisions/inbox/rca-drift-{sonnet,opus,codex}.md
- Issue gap audit: .squad/decisions/inbox/lead-issue-gap-audit.md
- Session checkpoint: .squad/decisions/inbox/session-16-checkpoint.md

## Directives in effect
- No main pushes, no duplicate PRs, always auto-merge squash
- CI RCA required before further work on repeat failures
- No workflow approvals for squad/copilot/Martin
- Always use high reasoning for all models
- PRs that change code must include docs updates
