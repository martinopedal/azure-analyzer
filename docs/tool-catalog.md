# Tool Catalog

> This is a navigation hub for tool catalog information. See detailed catalogs below.

Azure-analyzer includes 36 enabled analysis tools plus 1 optional tool. Tools are organized by consumer view (setup, what-it-does, docs links) and contributor view (manifest fields, install, upstream pins).

## Consumer view

For end-user setup, scope targeting, and quick reference on what each tool covers:

See [docs/reference/tool-catalog.md](./reference/tool-catalog.md)

## Contributor view

For full manifest fields, normalizer details, install methods, and upstream version pins:

See [docs/reference/tool-catalog-contributor.md](./reference/tool-catalog-contributor.md)

## Scope reference

| Scope | Targets |
|---|---|
| `subscription` | Single Azure subscription (`--SubscriptionId`). |
| `managementGroup` | Azure Management Group (`--ManagementGroupId`). |
| `tenant` | Entra ID tenant (`--TenantId`, requires `Connect-MgGraph`). |
| `repository` | GitHub or ADO repo (`--Repository` or `--RepoPath`). |
| `ado` | Azure DevOps organization (`--AdoOrg`). |
| `workspace` | Log Analytics / Sentinel workspace (`--SentinelWorkspaceId`). |

## Next steps

- **Permissions**: See [PERMISSIONS.md](../PERMISSIONS.md) for per-tool permission requirements and detailed scope guidance.
- **Getting started**: [docs/getting-started/](./getting-started/)
- **Advanced setup**: [docs/guides/](./guides/)
