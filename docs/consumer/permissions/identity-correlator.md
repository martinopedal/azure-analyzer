# Identity Correlator - Required Permissions

**Display name:** Identity Correlator

**Scope:** tenant | **Provider:** graph

The Identity Correlator runs in-process after all collectors complete. It seeds candidates from existing findings and cross-references them across dimensions; no additional permissions beyond whatever those collectors already had.

It also emits risk findings for privileged CI-linked identities, PAT-based ADO service connections, and identity reuse across multiple CI / CD bindings.

## Required permissions

None beyond the inherited collector scopes.

## Optional Graph lookup

| Optional path | Requirement | Why |
|---|---|---|
| `-IncludeGraphLookup` | Microsoft Graph `Application.Read.All` (or Security Reader) | Look up federated identity credentials on candidate apps |

Without `-IncludeGraphLookup`, correlator runs with zero additional permissions.
