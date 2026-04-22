# Open issue audit — 2026-04-22

- Repository: `martinopedal/azure-analyzer`
- Source: GitHub issue search API (`is:issue is:open`)
- Rules checked:
  - `squad` base label present
  - exactly one `squad:{member}` label present
  - stale candidate = `updated_at` older than 30 days **and** no linked PR

## Summary

- Open issues audited: **16**
- Well-labelled (`squad` + exactly one `squad:{member}`): **11**
- Untriaged (no `squad:{member}`): **0**
- Mislabelled (missing `squad` and/or not exactly one `squad:{member}`): **5**
- Stale candidates (>30d no activity, no linked PR): **0**

## Issue table

| Issue | Title | Updated | Assignees | Current labels | Recommended labels | Stale candidate | Notes |
|---:|---|---|---|---|---|---|---|
| #426 | feat: prompt for mandatory scanner parameters (GitHub org, ADO org, subscription, tenant, repo IDs) | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #427 | epic: large-scale tenant support (multi-tier reports + attack-path + resilience + viewer) | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #428 | feat: attack-path visualizer (Track A) | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #429 | feat: resilience map (Track B) | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #430 | feat: multi-tier report architecture + findings viewer (Track V) | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #431 | feat: policy enforcement visualization + AzAdvertizer gap-fill (Track C) | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #432 | feat: tool output fidelity audit + enrichment (Track D) | 2026-04-21 | — | enhancement, squad, squad:forge | squad, squad:forge, enhancement | No | OK |
| #433 | feat: LLM-assisted triage with rubberduck + tier-aware model selection (Track E) | 2026-04-21 | — | enhancement, squad, squad:atlas, squad:forge | squad, squad:atlas, enhancement | No | reduce `squad:{member}` labels from 2 to 1 |
| #434 | feat: auditor-driven report redesign across all tiers (Track F) | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #435 | feat: Phase 0 foundation PR — schema + tier picker + verification + edge-collector contract + fixtures | 2026-04-21 | — | enhancement, squad, squad:atlas | squad, squad:atlas, enhancement | No | OK |
| #439 | fix: CI failure in Docs Check -- Documentation update check Check for documentation updates 2026-04-21T21:38:01.4026505Z ##[error]error: Missing document [267ce1845328] | 2026-04-21 | — | squad, squad:forge, type:bug, priority:p1, ci-failure | squad, squad:forge, type:bug, priority:p1, ci-failure | No | OK |
| #441 | fix: CI failure in Docs Check -- Documentation update check Check for documentation updates 2026-04-21T21:38:21.3695395Z ##[error]error: Missing document [43ba87d0c686] | 2026-04-21 | — | squad, squad:forge, type:bug, priority:p1, ci-failure | squad, squad:forge, type:bug, priority:p1, ci-failure | No | OK |
| #446 | chore: scribe-merge 11 untriaged inbox files into decisions.md | 2026-04-22 | martinopedal, Copilot | squad, squad:atlas, squad:forge, type:chore, squad:copilot | squad, squad:copilot, type:chore | No | reduce `squad:{member}` labels from 3 to 1; linked PR present |
| #447 | docs: link sample-report.html and sample-report.md prominently in README | 2026-04-22 | martinopedal, Copilot | squad, squad:forge, squad:sentinel, type:docs, squad:copilot | squad, squad:copilot, type:docs | No | reduce `squad:{member}` labels from 3 to 1; linked PR present |
| #448 | chore: stale-issue audit and label hygiene pass | 2026-04-22 | martinopedal, Copilot | squad, squad:forge, squad:sentinel, type:chore, squad:copilot | squad, squad:copilot, type:chore | No | reduce `squad:{member}` labels from 3 to 1; linked PR present |
| #449 | docs: PERMISSIONS.md and README cross-reference consistency check | 2026-04-22 | martinopedal, Copilot | squad, squad:forge, squad:sage, type:docs, squad:copilot | squad, squad:copilot, type:docs | No | reduce `squad:{member}` labels from 3 to 1 |
