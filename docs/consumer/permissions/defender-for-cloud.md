# Microsoft Defender for Cloud - Required Permissions

**Display name:** Microsoft Defender for Cloud

**Scope:** subscription | **Provider:** azure

The Defender for Cloud wrapper reads three endpoints under `Microsoft.Security/*`: the subscription Secure Score (`secureScores/ascScore`), non-healthy assessments (`assessments`, paged), and active alerts (`alerts`, paged). The Secure Score lands on the Subscription entity; each non-healthy assessment and alert lands on its target AzureResource so Defender recommendations and threat alerts fold next to existing azqr / PSRule findings on the same resource.

## Required roles

| Token / scope | Why |
|---------------|-----|
| **Security Reader** at subscription scope | Required to read `Microsoft.Security/secureScores`, `Microsoft.Security/assessments`, and `Microsoft.Security/alerts` |
| (Alternative) **Reader** at subscription scope | Sufficient in tenants where Reader is permitted to read `Microsoft.Security/*`; Security Reader is the documented least-privilege role |

**API namespace used:** `Microsoft.Security/*` (read).

## Parameters

- `-SubscriptionId <guid>` (required, passed by orchestrator).
- `-OutputPath <dir>` (optional): write raw API JSON for audit.

## Sample command

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'defender-for-cloud'

# Across an MG (runs per child subscription)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'defender-for-cloud'
```

## What it scans

- Secure Score (current, max, percentage) for the subscription.
- Non-healthy assessments only (status `Unhealthy`); paged across up to 20 pages.
- Active Defender alerts (skips resolved and dismissed alerts), including MITRE tactics and techniques when present in the alert record.
- Per-assessment metadata: display name, severity, description, remediation guidance, target resource ID.
- Schema 2.2 metadata capture: Pillar (`Security`), Framework tags (for example MCSB and PCI when present), Defender portal deep links, evidence URIs, and wrapper tool version.

## What it does NOT do

- No remediation, no Quick Fix execution.
- No policy creation or modification (no `Microsoft.Authorization/policyAssignments` writes).
- No alert acknowledgment, dismissal, or rule changes.
- No Defender plan enable / disable on subscriptions.
- Gracefully **skips** when Defender for Cloud is not enabled on the subscription (HTTP 404 / 409 on `secureScores`).
