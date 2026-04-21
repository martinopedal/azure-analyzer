# Orchestration Log: Sage — Report UX References + ETL Gaps (azqr/PSRule/Defender/Prowler/Powerpipe)

**Started:** 2026-04-22T09:00:00Z  
**Agent:** Sage (Research)  
**Status:** Complete (v4, 4 turns of refinement)

## Summary

Produced a comprehensive research brief: **Report UX references** (`sage-report-ux-references.md`, 70 KB) covering:

- Part A: In-repo discoverability audit (sample assets unlinked from README/docs) + industry reference patterns (AzGovViz, azqr, Powerpipe, Prowler, Defender, PSRule).
- Part B+: Deeper visual specifics for Sentinel's mockup (hex codes, CSS specs, layout measurements).
- Part B++: Full 5-layer ETL gap matrices for azqr, PSRule, Defender for Cloud, Prowler, and Powerpipe.
- Schema 2.2 bump specification (13 new optional fields, single PR shape).

## Bugs Uncovered

1. **PSRule severity hardcode** — `Invoke-PSRule.ps1` sets `Severity = 'Medium'` for every finding regardless of the rule's actual level (Error/Warning/Information). Instant signal improvement when fixed.
2. **Defender missing regulatoryCompliance API call** — wrapper reads assessments + secure score but never calls the regulatory compliance endpoint, losing all CIS/NIST/PCI/ISO framework tags.
3. **azqr field-projection gap** — wrapper dumps raw JSON without extracting `RecommendationId`, `Impact`, or WAF Pillar mapping. Remediation is overloaded with the URL field.

## Key Deliverables

- Heat-map recommendation: **Control-Domain × Subscription** as default (endorsed by Sentinel).
- Sequencing plan: PR1 (PSRule severity fix) → PR2 (Schema 2.2) → PR3-5 (per-tool wrappers) → PR6 (report consumption).
- Prowler/Powerpipe: Prowler deferred until bundled; Powerpipe visuals-only (skip ETL).

## Outputs

- `.squad/decisions/inbox/sage-report-ux-references.md`
- Issues referenced: #300 (azqr), #301 (PSRule), #302 (Defender), #303 (Prowler), #304 (Powerpipe)
