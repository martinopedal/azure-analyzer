---
updated_at: 2026-04-20T15:55:00Z
focus_area: Post-restructure - awaiting next stream pickup
active_issues: [249, 250, 251, 252]
---

# What We're Focused On

The consumer-first documentation restructure is **complete and merged**. All 5 stream PRs landed (#243, #244, #246, #247, #253) and the master plan plus all completion records are archived under `.squad/decisions/archive/2026-04-20-consumer-first-restructure/`. See `.squad/orchestration-log.md` for the full rollup.

## Active queue

The doc-restructure directive is closed. No active stream is in flight.

## Candidate next pickups (from restructure follow-ups)

- [#249](https://github.com/martinopedal/azure-analyzer/issues/249) - restructure follow-up
- [#250](https://github.com/martinopedal/azure-analyzer/issues/250) - restructure follow-up
- [#251](https://github.com/martinopedal/azure-analyzer/issues/251) - restructure follow-up
- [#252](https://github.com/martinopedal/azure-analyzer/issues/252) - restructure follow-up

All four carry the `squad` label and are eligible for Ralph dispatch. Coordinator picks the next stream.

## Standing rules (still in force)

- Em-dash gate on every doc PR (`.copilot/copilot-instructions.md` line 221).
- Iterate-until-green: required check is `Analyze (actions)`.
- Branch protection: signed commits NOT required, 0 reviewers, linear history, squash-merge.
- Frontier-only model fallback chain when a charter-assigned model is unavailable.

