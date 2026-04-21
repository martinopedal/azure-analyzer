# Identity Graph Expansion - Required Permissions

**Display name:** Identity Graph Expansion

**Scope:** tenant | **Provider:** graph

The Identity Graph Expansion correlator builds a typed identity graph (entities **plus edges**) on top of the existing entity store. It emits five edge relations - `GuestOf`, `MemberOf`, `HasRoleOn`, `OwnsAppRegistration`, `ConsentedTo` - and risk findings for dormant guests, over-privileged SPN role assignments, and risky OAuth consents.

## Required permissions

| Optional path | Requirement | Why |
|---|---|---|
| `-IncludeGraphLookup` (live mode) | Microsoft Graph `User.Read.All`, `Application.Read.All`, `Directory.Read.All`, `Group.Read.All`, `DelegatedPermissionGrant.Read.All` | Enumerate B2B guests, group memberships, SPN ownership, and admin consents (read-only) |
| Pre-fetched mode (`-PreFetchedData`) | None | Tests / replay scenarios consume a JSON fixture directly |
| ARM RBAC enrichment | `Microsoft.Authorization/roleAssignments/read` at the target scope (Reader inherits this) | Build `HasRoleOn` edges + over-privileged findings |

All Graph and ARM calls are read-only and wrapped in `Invoke-WithRetry`. Edges are persisted to `entities.json` under the v3.1 `Edges` array (back-compat readers fall back to v3.0 bare-array layout).
