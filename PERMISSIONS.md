# Permissions Reference — azure-analyzer

## Principle
All tools run with the minimum permissions required. No write permissions anywhere.

## Azure permissions

| Tool | Scope | Required role | Justification |
|------|-------|--------------|---------------|
| azqr | Subscription | Reader | Reads resource configurations for compliance checks |
| PSRule for Azure | Subscription | Reader | Reads ARM/Bicep resources for rule evaluation |
| AzGovViz | Management Group | Reader + Directory.Read.All | Enumerates hierarchy, policies, RBAC assignments |
| ALZ Resource Graph queries | Subscription/Tenant | Reader | ARG queries are read-only |
| WARA (Start-WARACollector) | Subscription | Reader | Reads resources via ARG for reliability assessment |

## GitHub permissions

| Action | Required scope | Notes |
|--------|---------------|-------|
| Read repo contents | `contents: read` | Checked out source |
| Write security results | `security-events: write` | CodeQL SARIF upload |
| Read Actions | `actions: read` | CodeQL workflow scanning |

## Azure DevOps permissions
No ADO integration currently planned.

## Cost Management API (Invoke-CostManagementApi.ps1)
| Scope | Justification |
|-------|---------------|
| `Cost Management Reader` | Read budgets, alerts, and Advisor recommendations |

## What we do NOT need
- No Contributor or Owner roles
- No write permissions to any Azure resource
- No Key Vault access (no secrets stored in KV by this tool)
- No network permissions
