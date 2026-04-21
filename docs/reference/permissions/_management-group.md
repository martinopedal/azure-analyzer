# Management-group recursion

When you provide `-ManagementGroupId`, azure-analyzer automatically discovers all child subscriptions and tailors tool execution based on scope:

| Tool scope | Behavior |
|------------|----------|
| **Subscription-scoped** (azqr, PSRule, WARA, Azure Cost, FinOps, Defender for Cloud) | Runs **per discovered subscription** |
| **MG-scoped** (AzGovViz, ALZ Queries) | Runs **once at the MG level** |
| **Tenant-scoped** (Maester, Identity Correlator, Identity Graph Expansion) | Runs **once for the entire tenant** |
| **Workspace-scoped** (Sentinel Incidents, Sentinel Coverage) | Runs when `-SentinelWorkspaceId` is provided |
| **Repo-scoped** (Scorecard) | Independent of Azure hierarchy; runs for the specified repo only |
| **CLI-scoped** (zizmor, gitleaks, Trivy, bicep-iac, terraform-iac) | Local / cloned filesystem tools; run automatically, no cloud scope needed |
| **ADO-scoped** (ADO Connections, ADO Pipeline Security, ADO Repo Secrets, ADO Pipeline Correlator) | Independent of Azure hierarchy; runs when `-AdoOrg` is provided |

## Required permissions for recursion

- `Reader` on the management group (auto-inherited to all child subscriptions)
- **OR** `Reader` on each individual subscription (if you lack MG-level permissions)

## Discovery behavior

- **Tenant root group:** include all subscriptions in the tenant.
- **Specific MG:** include only the MG and its direct children (recursive).
- **No recursion:** use `-Recurse:$false` to scan only the specified MG, without discovering child subscriptions.

## Portfolio rollup note

The portfolio heatmap and management-group breadcrumb perform one extra Azure Resource Graph read over the `subscriptions` entries in `resourcecontainers`, projecting `properties.managementGroupAncestorsChain` for management-group ancestry context. This is still covered by the same **Reader** role at the management-group scope. No new Azure role, no write action, and no role-assignment permission is required.

## Examples

```powershell
# Scan entire tenant from root MG
# Discovers all subscriptions; azqr/PSRule/WARA run per sub
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "00000000-0000-0000-0000-000000000000"

# Scan specific MG subtree
# E.g., "my-landing-zone" - discovers child subs, runs sub-tools per discovery
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-landing-zone"

# MG-level tools only, skip per-subscription recursion
# AzGovViz and ALZ Queries run for "prod-mg"; azqr/PSRule/WARA skipped
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "prod-mg" -Recurse:$false

# Combine MG recursion with tool filtering
# Scan entire MG tree, but only run Maester (Entra ID security)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "tenant-root" -IncludeTools 'maester'

# Scan MG tree for governance + reliability, skip compliance checks
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-mg" -ExcludeTools 'azqr','psrule'
```
