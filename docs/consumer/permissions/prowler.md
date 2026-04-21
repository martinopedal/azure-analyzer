# Prowler - Required Permissions

**Display name:** Prowler (Azure security posture)

**Scope:** subscription | **Provider:** azure

Prowler runs read-only checks against Azure resources and emits compliance mappings (CIS, NIST, ISO27001, PCI-DSS, HIPAA, SOC2, MITRE ATT&CK, GDPR, FedRAMP) with remediation snippets and deep links to check documentation.

## Required roles

| Token / scope | Why |
|---|---|
| **Security Reader** at subscription scope | Recommended least-privilege role for Microsoft.Security posture APIs used by Prowler checks |
| (Alternative) **Reader** at subscription scope | Works in many tenants for broad Azure resource read access |

## Parameters

- `-SubscriptionId <guid>` (required)
- `-OutputPath <dir>` (optional)

## Sample command

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'prowler'
```

## What it does NOT do

- No remediation changes in Azure resources.
- No policy assignment or RBAC writes.
- No security alert state mutation.
