# Microsoft Sentinel (Coverage / Posture) - Required Permissions

**Display name:** Microsoft Sentinel (Coverage / Posture)

**Scope:** workspace | **Provider:** azure

The Sentinel coverage wrapper enumerates the same Log Analytics workspace's Sentinel posture surface via the `Microsoft.SecurityInsights` REST provider plus Log Analytics `savedSearches`. It surfaces detection-readiness gaps (missing or disabled analytic rules, undermonitored connector counts, empty / short-TTL watchlists, missing hunting queries) as findings keyed to the workspace ARM resource. Pairs with `sentinel-incidents` and uses the same RBAC.

## Required roles

| Token / scope | Why |
|---------------|-----|
| **Microsoft Sentinel Reader** on the workspace (or its resource group / subscription) | Required to list `Microsoft.SecurityInsights/alertRules`, `watchlists`, `watchlistItems`, and `dataConnectors` |
| **Log Analytics Reader** on the workspace | Required to list `Microsoft.OperationalInsights/workspaces/savedSearches` (hunting queries) |
| (Alternative) **Reader** on the workspace resource group | Sufficient when Reader permits the read endpoints above |

## API endpoints used (read-only)

- `Microsoft.SecurityInsights/alertRules` (list): analytic rule inventory and `enabled` / `lastModifiedUtc` state.
- `Microsoft.SecurityInsights/watchlists` (list): watchlist metadata (`defaultDuration`, `watchlistAlias`).
- `Microsoft.SecurityInsights/watchlists/{alias}/watchlistItems` (list): item count for empty-watchlist detection.
- `Microsoft.SecurityInsights/dataConnectors` (list): connector inventory.
- `Microsoft.OperationalInsights/workspaces/savedSearches` (list): saved searches filtered to category `Hunting Queries`.

## Parameters

- `-SentinelWorkspaceId <ARM-resource-id>` (required): full ARM resource ID of the Sentinel-linked Log Analytics workspace.
- `-SentinelLookbackDays <int>` (optional, default `30`): accepted for orchestrator-shape parity with `sentinel-incidents`; the wrapper currently uses a fixed 7-day staleness threshold for disabled analytic rules and a 30-day TTL threshold for watchlists.

## Sample command

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" `
  -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>" `
  -IncludeTools 'sentinel-coverage'
```

## What it scans

- Analytic-rule inventory (counts, enabled / disabled split, `lastModifiedUtc`).
- Data-connector inventory (count vs. minimum healthy threshold of 3).
- Watchlist inventory + per-watchlist `defaultDuration` (TTL parsing) + per-watchlist item count.
- Hunting-query inventory (saved searches whose `properties.category` matches `(?i)hunting`).

## What it does NOT do

- No analytic-rule create / update / delete / enable / disable.
- No watchlist mutation, item upload, or deletion.
- No data-connector connect / disconnect.
- No saved-search create / update / execute.
- Gracefully **skips** with `Status=Skipped` when `Microsoft.SecurityInsights` returns HTTP 404 / 409 (Sentinel not onboarded on the workspace).

## Categories deferred (require telemetry the read APIs do not expose)

- *Enabled analytic rules with no incidents in 30 days*: needs a SecurityIncident KQL crossref per rule.
- *Hunting queries not run in 90 days*: `savedSearches` does not return a last-execution timestamp; would need workspace audit-log telemetry.
