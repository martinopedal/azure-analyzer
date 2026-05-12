# conditional-access-graph - Required Permissions

**Display name:** Conditional Access Policy Graph

**Scope:** tenant | **Provider:** graph

The Conditional Access (CA) policy graph wrapper pulls every CA policy
from Microsoft Graph (`/identity/conditionalAccess/policies`) and emits:

- One `ConditionalAccessPolicy` entity per policy.
- `AppliesTo` and `Excludes` edges between the policy and every
  user / group / application / named location it gates.
- Findings for the high-risk gaps documented in the design note
  (`docs/design/graph-mapping-integration.md` section 4.4): disabled
  policy covering Global Administrator, Global Administrator excluded
  from an MFA-requiring policy, report-only mode, oversized break-glass
  exclusion lists, enabled policy with no strong grant control.

The wrapper is **read-only**: it never mutates a CA policy.

## Required permissions

| Mode | Auth | Notes |
|---|---|---|
| Default (live Microsoft Graph) | Delegated user or Entra app registration with `Policy.Read.All` and `Directory.Read.All` | Both scopes are read-only. Connect with `Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All"`. |
| Offline / fixture / test | None | Pass `-PreFetchedData` (a `PSCustomObject` with `.Policies = @(...)`) to bypass the live Graph call. Used by `-FixtureMode` and the wrapper test suite. |

No write scopes are required. No Azure RBAC, GitHub, or ADO scopes are
required.

## Local module requirement

The live mode requires the following PowerShell modules on `PATH`:

- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Identity.SignIns`
- `Microsoft.Graph.Identity.DirectoryManagement`

When `Get-MgContext` returns `$null` (module loaded but no
`Connect-MgGraph` has happened) the wrapper skips with status
`Skipped` and a `MissingDependency` `FindingError`, mirroring the
behaviour of the other graph-family wrappers.

## Security invariants

- HTTPS-only outbound to `graph.microsoft.com`.
- Every Graph call wrapped with `Invoke-WithRetry` (handles 429
  throttling).
- All policy display names + error output passes through
  `Remove-Credentials` before any persistence.
- The wrapper deliberately omits free-text claim payloads from finding
  `Detail` to avoid leaking codenames or product IDs from policy
  display names.
- Returns the canonical v1 envelope (`Source`, `SchemaVersion = '1.0'`,
  `Status`, `Message`, `Findings`, `Errors`, plus the additive
  `Policies` projection consumed by `Normalize-ConditionalAccessGraph`).
