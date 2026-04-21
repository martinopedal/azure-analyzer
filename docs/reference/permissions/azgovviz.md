# AzGovViz - Required Permissions

**Display name:** AzGovViz

**Scope:** managementGroup | **Provider:** azure

## Required roles

| Capability | Scope | Role | Why |
|---|---|---|---|
| Governance hierarchy crawl | Management Group | **Reader** | Crawls governance hierarchy, policy assignments, and RBAC role assignments under the MG |

## What it does with these permissions

AzGovViz walks the management-group tree, lists policy assignments / definitions / exemptions, and enumerates role assignments per scope. All calls are read-only via standard ARM endpoints.

## How to grant

See [`_troubleshooting.md`](_troubleshooting.md#how-to-grant-azure-reader). For MG scope replace `--scope /subscriptions/...` with `--scope /providers/Microsoft.Management/managementGroups/<mg-id>`.
