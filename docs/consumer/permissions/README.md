# Permissions detail

This folder hosts the per-tool and per-scenario permission pages that used to live inline in the root `PERMISSIONS.md`. The root file remains the consumer-facing summary plus a manifest-driven index pointing here.

## Cross-cutting pages

- [`_summary.md`](_summary.md) - Cross-tool permission matrix, permission tiers, least-privilege scenarios, what we do NOT need.
- [`_continuous-control.md`](_continuous-control.md) - GitHub Actions OIDC federation and Azure Function App managed identity for scheduled / always-on runs (#165).
- [`_multi-tenant.md`](_multi-tenant.md) - Per-tenant requirements when running with `-TenantConfig` / `-Tenants` (#163).
- [`_management-group.md`](_management-group.md) - MG recursion behaviour, scope-aware tool execution, examples.
- [`_troubleshooting.md`](_troubleshooting.md) - Auth troubleshooting recipes for Azure, Microsoft Graph, GitHub.

## Per-tool pages

One page per enabled tool in `tools/tool-manifest.json`. The index in the root [`PERMISSIONS.md`](../../../PERMISSIONS.md) is regenerated from the manifest by `scripts/Generate-PermissionsIndex.ps1` and enforced by the `permissions-pages-fresh` CI check.

When you add a new enabled tool to the manifest you MUST also add a `docs/consumer/permissions/<name>.md` page (even a one-paragraph "no permissions required" stub is fine). The `permissions-pages-fresh` check fails the PR otherwise.
