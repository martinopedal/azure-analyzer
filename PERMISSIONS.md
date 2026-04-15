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
| Maester | Tenant (Entra ID) | Directory.Read.All, Policy.Read.All, Reports.Read.All | Reads Entra ID security configuration via Microsoft Graph; requires `Connect-MgGraph` before running

## GitHub permissions

| Action | Required scope | Notes |
|--------|---------------|-------|
| Read repo contents | `contents: read` | Checked out source |
| Write security results | `security-events: write` | CodeQL SARIF upload |
| Read Actions | `actions: read` | CodeQL workflow scanning |

## Supply Chain (Scorecard) permissions

| Tool | Scope | Required credential | Justification |
|------|-------|---------------------|---------------|
| OpenSSF Scorecard | Repository | `GITHUB_AUTH_TOKEN` (optional) | GitHub API token for authenticated scans (recommended to avoid rate limiting); reads repository metadata and branch protection settings |

## Azure DevOps permissions
No ADO integration currently planned.

## What we do NOT need
- No Contributor or Owner roles
- No write permissions to any Azure resource
- No Key Vault access (no secrets stored in KV by this tool)
- No network permissions
