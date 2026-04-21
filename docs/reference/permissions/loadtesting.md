# Azure Load Testing (Failed and Regressed Runs) - Required Permissions

**Display name:** Azure Load Testing (Failed and Regressed Runs)

**Scope:** subscription | **Provider:** azure

The Azure Load Testing wrapper lists `Microsoft.LoadTestService/loadTests` resources, enumerates tests and recent test runs, and reports failed or cancelled runs plus metric regressions against a prior baseline run.

## Required roles

| Token / scope | Why |
|---|---|
| **Reader** on the Load Test resource, resource group, or subscription | Required to list load test resources, tests, and test runs through ARM read APIs |

Reader is sufficient for this wrapper because it performs read-only inventory and analysis. It does not create or execute test runs.

## API endpoints used (read-only)

- `Microsoft.LoadTestService/loadTests` (list and get)
- `Microsoft.LoadTestService/loadTests/tests` (list)
- `Microsoft.LoadTestService/loadTests/tests/{testName}/test-runs` (list)

## Parameters

- `-SubscriptionId <guid>` (required)
- `-ResourceGroup <name>` (optional filter)
- `-LoadTestResourceName <name>` (optional filter)
- `-DaysBack <int>` (default `30`)
- `-RegressionThresholdPercent <int>` (default `10`)
- `-IncludeHealthyRuns` (optional, default off)

## Sample command

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'loadtesting'
```

## What it scans

- Failed or cancelled runs in the configured time window.
- Pass/fail criteria failures.
- Regressions against the previous run for:
  - response time p95
  - error rate
  - requests per second

## What it does NOT do

- No test creation, update, or deletion.
- No test-run execution, cancellation, or rerun.
- No write actions on Azure resources.
