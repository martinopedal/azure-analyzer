# Application Insights Performance Signals - Required Permissions

**Display name:** Application Insights Performance Signals

**Scope:** subscription | **Provider:** azure

The Application Insights wrapper discovers `Microsoft.Insights/components` resources and runs read-only KQL against telemetry tables (`requests`, `dependencies`, `exceptions`) to detect slow endpoints, dependency failures, and high-volume exception clusters.

## Required roles

| Token / scope | Why |
|---|---|
| **Reader** on the Application Insights component, resource group, or subscription | Required to discover App Insights resources and read resource metadata |
| **Log Analytics Reader** (workspace-based components) | Required to query telemetry when the component is linked to a workspace |

Reader plus Log Analytics Reader is sufficient for this wrapper. It performs no write actions.

## API and query surfaces used (read-only)

- ARM discovery: `Microsoft.Insights/components` (list/get)
- App Insights query APIs via Az cmdlets:
  - `Invoke-AzApplicationInsightsQuery`
  - `Invoke-AzOperationalInsightsQuery` fallback (workspace-backed)
- Telemetry tables: `requests`, `dependencies`, `exceptions`

## Parameters

- `-SubscriptionId <guid>` (required)
- `-ResourceGroup <name>` (optional filter)
- `-AppInsightsName <name>` (optional filter)
- `-TimeRangeHours <int>` (default `24`)

## Sample command

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'appinsights'
```

## What it scans

- Slow requests where duration exceeds 5 seconds and volume is above threshold.
- Dependency failures where failed call count is above threshold.
- Exception clusters where problemId count is above threshold.

## What it does NOT do

- No telemetry mutation.
- No component/workspace configuration changes.
- No write actions on Azure resources.
