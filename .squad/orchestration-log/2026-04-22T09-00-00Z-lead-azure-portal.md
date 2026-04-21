# Orchestration Log: Lead — Azure Portal UI Patterns (WARA + Sentinel)

**Started:** 2026-04-22T09:00:00Z  
**Agent:** Lead (Architecture & Planning)  
**Status:** Complete

## Summary

Produced a research brief: **Azure-native tool UI patterns** (`lead-azure-portal-ui-patterns.md`, 56 KB) — deep-dives on WARA (Well-Architected Reliability Assessment) and Microsoft Sentinel, mapping their Microsoft design language to our v3 FindingRow + EntityStore schema.

## Bugs Uncovered

1. **WARA `ImpactedResources[0]` truncation** — wrapper takes only the first element of the `ImpactedResources` array (line 102), losing N-1 resources and breaking the effort axis of the Impact×Effort matrix.
2. **WARA `Remediation`/`LearnMoreUrl` aliasing** — line 111 sets both fields to the same value. Remediation text is lost; only the URL survives.

## Key Findings

- WAF Impact×Effort 3×3 matrix is the single most actionable UI primitive from the Microsoft design language. Deterministically derivable from existing data (Impact + ImpactedResourceCount).
- Sentinel Incidents KQL projection missing 7 high-value columns: `Tactics`, `Techniques`, `RelatedAnalyticRuleIds`, `AlertIds`, `Comments`, `Labels`, `FirstActivityTime/LastActivityTime`.
- Two-palette severity approach: WAF pillar colors for posture/recommendations, Defender colors for threat/incident severity. Both palettes intentional — different signals.
- Schema 2.2 additions proposed: 17 new optional parameters on `New-FindingRow` covering Pillar, MITRE, EntityRefs, Status, Classification, and more.

## Outputs

- `.squad/decisions/inbox/lead-azure-portal-ui-patterns.md`
- Issues referenced: #308 (WARA), #309 (Sentinel Incidents), #310 (Sentinel Coverage)
