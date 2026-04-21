# Entity Model and Deduplication

**Status**: In development

Full entity model specification coming soon.

## Overview

The azure-analyzer v3 entity model separates findings from entities, enabling cross-tool correlation and graph-based attack path visualization.

## Entity Types

Canonical entity types (from `modules/shared/Schema.ps1`):

- `AzureResource` — Azure ARM resources (VMs, storage accounts, databases, etc.)
- `Subscription` — Azure subscriptions
- `ManagementGroup` — Azure management groups
- `Tenant` — Entra ID tenants
- `User` — Entra ID users
- `ServicePrincipal` — Entra ID service principals / app registrations
- `Group` — Entra ID groups
- `Repository` — GitHub/ADO repositories
- `IaCFile` - Infrastructure-as-Code files (Terraform, Bicep, etc.)
- `Workflow` — GitHub Actions workflows
- `Pipeline` — Azure DevOps pipelines
- `BuildRun` — Pipeline execution instances
- `Container` — Kubernetes pods/containers
- `Cluster` — Kubernetes clusters
- `Namespace` — Kubernetes namespaces

## Canonical IDs

Entities use canonical ID formats (via `ConvertTo-CanonicalEntityId`):

- ARM resources: lowercase resource ID (e.g., `/subscriptions/{guid}/resourcegroups/{rg}/providers/microsoft.compute/virtualmachines/{vm}`)
- Tenant: `tenant:{guid}`
- User: `user:{upn}` or `user:{objectId}`
- Service principal: `appId:{guid}`
- Repository: `repo:{owner}/{name}`
- IaCFile: `iacfile:{repo-slug}:{relative-path}` (e.g., `iacfile:github.com/org/repo:terraform/main.tf`)

## Entity Store

v3 output schema:

- `results.json` — Legacy 10-field findings (back-compat)
- `entities.json` — Full v3 entity graph with relationships

See `modules/shared/EntityStore.ps1` for implementation.
