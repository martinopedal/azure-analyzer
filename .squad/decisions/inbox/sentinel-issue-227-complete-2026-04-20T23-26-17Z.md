# Sentinel completion record - issue #227

## Issue
- #227 feat(reports): top recommendations by impact panel

## Delivery summary
- Added a Top recommendations by impact panel to the top of the Findings tab in `New-HtmlReport.ps1`.
- Added `-TopRecommendationsCount` (default `10`) to configure the number of recommendations rendered.
- Grouping is `RuleId` first (FindingRow v2.1), with fallback to the existing level-3 title-prefix derivation via `Get-FindingRuleKey`.
- Cards include highest severity, impact score, resource count, occurrence count, `Fix it` link, inline affected-resource details, and a tree filter action.

## Impact formula constants (tunable)
- Severity weights:
  - Critical = 10
  - High = 5
  - Medium = 2
  - Low = 1
  - Info = 0.1
- Formula: `impact = severity_weight x occurrence_count x resource_breadth`
- `occurrence_count`: findings per grouped recommendation
- `resource_breadth`: distinct affected resources, deduped by canonical entity key (`EntityId`, fallback `ResourceId`)

## Validation
- Baseline before change: `Invoke-Pester -Path .\tests -CI` passed with `1302` tests passed.
- After change: `Invoke-Pester -Path .\tests -CI` passed with `1305` tests passed.
- Added coverage: `tests/reports/Top-Recommendations.Tests.ps1`.

## PR and merge
- PR: https://github.com/martinopedal/azure-analyzer/pull/283
- Merge commit: `9480aacce877f54b4fef36e420aabdd9fe091ebb`
- Merged at: `2026-04-20T21:25:08Z`

## Notes
- Panel integrates with existing severity strip (#226), collapsible tree (#229), and framework matrix (#230).
- Issue #227 was manually closed after merge because the auto-close keyword in PR metadata did not close it.
