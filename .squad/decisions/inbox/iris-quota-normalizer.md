# Iris Decision Brief — Azure Quota normalizer severity ladder (#323)

## Context
Issue #323 introduces `modules/normalizers/Normalize-AzureQuotaReports.ps1` for v1 wrapper output from #322. We had to finalize the severity behavior for percent-based quota usage while honoring the locked compliance formula.

## Decision
Use this ladder in the normalizer:
- `UsagePercent >= 99` => `Critical`
- `UsagePercent >= 95` => `High`
- `UsagePercent >= Threshold` => `Medium`
- below threshold => `Info`

Compliance stays locked to:
- `Compliant = (UsagePercent < Threshold)` with fallback `Threshold = 80` when absent.

## Rationale
- Aligns with `.squad/decisions.md` schema mapping for azure-quota.
- Keeps risk escalation intuitive near exhaustion (`>=99` becomes immediate critical capacity risk).
- Preserves full record coverage: compliant rows still emit as informational findings so trend/heatmap consumers can see healthy capacity headroom.

