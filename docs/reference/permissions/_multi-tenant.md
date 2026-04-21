# Multi-tenant fan-out (#163)

When `-TenantConfig` or `-Tenants` is supplied, `Invoke-AzureAnalyzer.ps1` invokes itself once per (tenant, subscription) pair as a child `pwsh` process. The orchestrator does **not** elevate or impersonate; it relies on the calling user's existing cross-tenant access. Each tenant must independently grant the same read-baseline scopes that single-tenant runs require:

| Surface | Per-tenant requirement |
|---------|------------------------|
| Azure resources / ARG / Defender / Cost (`alz-queries`, `azqr`, `psrule`, `wara`, `azure-cost`, `defender-for-cloud`, `azgovviz`, `finops`) | **Reader** on each subscription (or **Management Group Reader** when scoping by MG) |
| Microsoft Sentinel (`sentinel-coverage`, `sentinel-incidents`) | **Microsoft Sentinel Reader** + **Log Analytics Reader** on each workspace |
| Microsoft Graph / Entra (`maester`) | Same Graph scopes as single-tenant runs (`Get-MtGraphScope`); the calling user must be a member or B2B guest of each tenant being scanned |
| Azure DevOps (`ado-connections`, `ado-pipelines`) | Per-org PAT with read scope (orchestrator passes `-AdoPat` through to children unchanged) |

## Out of scope for v1 (deferred to follow-up issues)

- Service-principal **impersonation across tenants** (would require app multi-tenant consent + per-tenant token acquisition; v1 inherits the user's interactive context).
- Combining `-TenantConfig` / `-Tenants` with `-ManagementGroupId` (per-tenant MG resolution is intentionally rejected; supply explicit `subscriptionIds` per tenant in the config instead).

Per-tenant outputs are written to `<OutputPath>/<tenantId>/`; cross-tenant aggregation is summary-only (`multi-tenant-summary.json` / `.html`) and never co-mingles findings from different tenants in the same file.
