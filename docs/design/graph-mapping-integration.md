# Graph Mapping Integration

Status: In Review
Owners: squad
Related: #428 (attack-path visualizer), #506 (auditor report), `identity-correlator`, `identity-graph-expansion`

## 1. Problem statement

Today the repo has two graph-family wrappers (`identity-correlator`,
`identity-graph-expansion`) covering five edge types: `GuestOf`,
`MemberOf`, `HasRoleOn`, `OwnsAppRegistration`, `ConsentedTo`. That is a
useful start, but auditors and incident responders consistently ask for
graph relationships we do not yet emit:

- Conditional Access policy applicability (which users / groups / apps a
  given policy gates, including exclusions).
- PIM eligibility versus active role assignments (who *can* become
  privileged versus who *is* privileged right now).
- Transitive app permission inheritance (delegated +
  application-permission grants chained through service principals).
- Hybrid identities (which Entra users are shadows of an on-prem AD
  user, so on-prem compromise paths surface in the same graph).
- The de-facto attack-path tooling the security community uses
  (BloodHound / AzureHound, ROADtools, GraphRunner).

The output must extend the existing v3 entity store (entities.json +
edges.json via `New-Edge` / `EntityStore.AddEdge`) so the attack-path
visualizer (Track A) and the auditor report (Track F) can consume it
without a schema rewrite.

## 2. Constraints

- Reader-only: no write scopes. Consistent with `PERMISSIONS.md`.
- HTTPS-only outbound; host allow-list enforced by `Installer.ps1` and
  `RemoteClone.ps1`.
- Schema-additive: entity types and edge relations widen
  back-compatibly. No rename, no enum tightening.
- Throttle-safe: every Graph call wrapped with `Invoke-WithRetry`.
- Secret-safe: API keys and tenant identifiers scrubbed via
  `Remove-Credentials` before any persistence.
- Fixture-mode friendly: each tool ships a fixture so
  `Invoke-AzureAnalyzer.ps1 -FixtureMode` exercises the normalizer
  without live tenant credentials.

## 3. Vendor matrix (four families)

| Family | Tool | License | Auth | Why we want it | Scope |
| --- | --- | --- | --- | --- | --- |
| Azure-native | Conditional Access policy graph | Microsoft Graph (built-in) | `Policy.Read.All` | Closes the audit ask "show me which users / apps a CA policy actually applies to". Worked example for R1. | tenant |
| Azure-native | PIM eligibility / activation graph | Microsoft Graph | `RoleManagement.Read.Directory` | Distinguishes standing privilege from eligible privilege. | tenant |
| Azure-native | Microsoft Entra Permissions Management | Microsoft.EntraPermissionsManagement REST | Entra Permissions Management Reader | RBAC right-sizing + permission-creep graph (formerly CloudKnox). | tenant |
| Entra-native | App permission transitivity (built-in) | Microsoft Graph | `Application.Read.All`, `DelegatedPermissionGrant.Read.All` | Expand `OAuth2PermissionGrants` + `AppRoleAssignments` into transitive `EffectivePermission` edges. Closes a gap in `identity-graph-expansion`. | tenant |
| Entra-native | Hybrid identity edges (built-in) | Microsoft Graph | `User.Read.All` | `OnPremisesSyncEnabled` users get `OnPremShadow` edges so on-prem AD risk shows up in the same graph. | tenant |
| Commercial / standard | AzureHound (SpecterOps) | Apache-2.0 | Entra app registration with read scopes | De-facto attack-path collector; emits BloodHound-compatible JSON. | tenant |
| Commercial / standard | BloodHound CE (SpecterOps) | Apache-2.0 (CE backend) | Neo4j + AzureHound JSON | Optional one-way ingest of edges into a local BloodHound CE instance for triage. | tenant |
| Commercial / standard | Semperis Forest Druid / Purple Knight | Commercial | Vendor licence | Tier-4, gated on env-var presence. | tenant |
| OSS researched | ROADtools / ROADrecon (Dirk-jan Mollema) | Apache-2.0 | Entra device-code or refresh token | OSS Entra graph standard; SQLite + JSON export. | tenant |
| OSS researched | GraphRunner (Black Hills Infosec) | MIT | Entra device-code | Post-compromise Graph enumeration in passive read-only mode. | tenant |

Explicitly deferred: MicroBurst (NetSPI) write-mode commands, ScubaGear
(M365 baseline; covered by Maester), AADInternals (offensive-only).

## 4. Architecture

### 4.1 Manifest registration

Eight new entries land in `tools/tool-manifest.json` under
`provider: "graph"`. Names remain alphabetically sorted to satisfy
`tests/manifest/Manifest.Sorted.Tests.ps1`.

| Tool | scope | install.kind | enabled (initial) |
| --- | --- | --- | --- |
| azurehound | tenant | cli | false (R2) |
| bloodhound-ce | tenant | none | false (R3) |
| conditional-access-graph | tenant | psmodule | true (worked example, R1) |
| entra-permissions-mgmt | tenant | psmodule | false (R3, Azure-native) |
| forest-druid | tenant | none | false (R4, commercial) |
| graphrunner | tenant | gitclone | false (R2) |
| pim-graph | tenant | psmodule | false (R2, Azure-native) |
| roadrecon | tenant | pipx | false (R2) |

Tools ship `enabled: false` until their wrapper, normalizer, fixture,
and tests land. Pre-registration in this PR means the wrapper-ratchet
baseline absorbs the entire family in one commit, avoiding the
"parallel agents collide on the manifest" failure mode.

### 4.2 Schema additions

Additive enum widenings only:

- `Schema.ps1` `$script:EntityTypes` gains `ConditionalAccessPolicy`,
  `NamedLocation`, `OnPremUser`.
- `Schema.ps1` `$script:Platforms` gains `OnPrem`.
- `Schema.ps1` `$script:EdgeRelations` gains `AppliesTo`, `Excludes`,
  `EligibleFor`, `ActiveAs`, `EffectivePermission`, `OnPremShadow`.
- `Get-PlatformForEntityType` maps `ConditionalAccessPolicy -> Entra`,
  `NamedLocation -> Entra`, `OnPremUser -> OnPrem`.
- `[ValidateSet]` blocks for `ConvertTo-CanonicalEntityId`,
  `Get-PlatformForEntityType`, and `New-EntityStub` widen to include
  the three new types (back-compatible).
- `Canonicalize.ps1` adds canonical-id producers:
  `ConditionalAccessPolicy -> cap:{guid}`,
  `NamedLocation -> loc:{guid}`,
  `OnPremUser -> onprem:user:{sid}`.

AzureHound brings its own edge taxonomy (`AZGlobalAdmin`, `AZHasRole`,
etc.); those collapse onto our existing `HasRoleOn` and
`OwnsAppRegistration` edges in the AzureHound normalizer (R2). No new
enum members are needed for AzureHound.

### 4.3 Wrappers and normalizers

Each wrapper lives at `modules/Invoke-<Tool>.ps1` and follows the
established contract:

- Dot-source `Sanitize.ps1`, `Errors.ps1`, `New-WrapperEnvelope.ps1`,
  `Retry.ps1`, `Schema.ps1`, `Canonicalize.ps1` with inline fallback
  stubs (matches `Invoke-DnsTwist.ps1` and `Invoke-IdentityGraphExpansion.ps1`).
- `[CmdletBinding()]` declared.
- HTTPS-only outbound; the graph host allow-list is the existing
  Microsoft Graph + ADO + GitHub allow-list.
- 300 s `Invoke-WithTimeout` per external CLI (AzureHound, ROADrecon,
  GraphRunner).
- `Invoke-WithRetry` on every Graph call.
- Returns a v1 envelope (`SchemaVersion: 1.0`, `Findings`, optional
  `Edges`) per the existing correlator-envelope contract.

Normalizer contract:

- Converts the v1 envelope to v2 `FindingRow` records via
  `New-FindingRow` and (when applicable) v3 `Edge` records via
  `New-Edge`.
- Severity maps onto the canonical 5-level enum.
- Sets `Pillar=Identity` and `Domain=IdentityGraph` for the
  identity-graph family.
- Anchors findings to canonical entity IDs via
  `ConvertTo-CanonicalEntityId` so reports collapse correctly.

### 4.4 Conditional Access policy graph (R1 worked example)

The R1 wrapper consumes the Microsoft Graph
`/identity/conditionalAccess/policies` endpoint and emits one
`ConditionalAccessPolicy` entity per policy, plus edges:

- `AppliesTo`: policy -> User|Group|Application|Role|NamedLocation
- `Excludes`: policy -> User|Group|Application|Role|NamedLocation

Findings are emitted for high-risk gaps:

| Indicator | Severity |
| --- | --- |
| Policy in `disabled` state but covers privileged role members | High |
| Policy in `enabledForReportingButNotEnforced` state for >30 d | Medium |
| Policy excludes Global Administrator role from MFA requirement | Critical |
| Policy targets all users but excludes specific accounts (break-glass beyond 2) | Medium |
| Named location uses `IsTrusted=true` for a non-corporate IP range | High |
| Policy does not require MFA for any condition | Low |

The wrapper accepts a pre-fetched data bag (`-PreFetchedData`) so tests
and `-FixtureMode` can exercise the normalizer without live Graph
credentials, mirroring the `Invoke-IdentityGraphExpansion` pattern.

### 4.5 Conditional Access JSON schema (consumed by the wrapper)

The wrapper accepts the standard `microsoft.graph.conditionalAccessPolicy`
shape returned by Graph. The fixture under
`tests/fixtures/conditional-access-graph-output.json` mirrors a v1
envelope wrapping a small representative policy set:

```json
{
  "Source": "conditional-access-graph",
  "SchemaVersion": "1.0",
  "Status": "Success",
  "Policies": [
    {
      "id": "<guid>",
      "displayName": "<name>",
      "state": "enabled|disabled|enabledForReportingButNotEnforced",
      "conditions": {
        "users":     { "includeUsers": [], "excludeUsers": [], "includeGroups": [], "excludeGroups": [], "includeRoles": [], "excludeRoles": [] },
        "applications": { "includeApplications": [], "excludeApplications": [] },
        "locations": { "includeLocations": [], "excludeLocations": [] }
      },
      "grantControls":   { "operator": "AND|OR", "builtInControls": ["mfa","compliantDevice"] },
      "sessionControls": { ... }
    }
  ]
}
```

### 4.6 Permissions delta

| Source | New scope |
| --- | --- |
| Conditional Access policy graph | `Policy.Read.All`, `Directory.Read.All` (read-only) |
| PIM graph (R2) | `RoleManagement.Read.Directory`, `RoleAssignmentSchedule.Read.Directory` |
| Entra Permissions Management (R3) | Permissions Management Reader role |
| App permission transitivity (R2) | `Application.Read.All`, `DelegatedPermissionGrant.Read.All` |
| AzureHound (R2) | Entra app registration with `Directory.Read.All` |
| ROADrecon (R2) | Device-code interactive auth (no app-registration required) |
| GraphRunner (R2) | Device-code interactive auth |
| BloodHound CE (R3) | None (consumes AzureHound JSON output) |
| Forest Druid (R4) | Commercial licence |

No write scopes anywhere, consistent with the Reader-only invariant.

### 4.7 Security invariants

- HTTPS-only outbound to `graph.microsoft.com`.
- 300 s `Invoke-WithTimeout` on every external process launch.
- All Graph payloads pass through `Remove-Credentials` before any
  finding, edge, or error is written to disk. CA policy display names
  occasionally leak product / codename info; the sanitizer regex covers
  the standard secret patterns and the wrapper deliberately omits
  free-text claim payloads from finding `Detail`.
- Allow-listed package managers for installer (`pipx` for ROADrecon,
  `gitclone` for GraphRunner against `github.com/dafthack/GraphRunner`).
- Tokens scrubbed from `.git/config` immediately post-clone (handled by
  `RemoteClone.ps1`).

### 4.8 Testing

- One normalizer test per tool with a realistic fixture under
  `tests/fixtures/<tool>-output.json`.
- One wrapper test per tool covering: success path with PreFetchedData,
  Graph throttling retry, missing-module skip, sanitization of tenant
  IDs from error output.
- `WrapperConsistencyRatchet.Tests.ps1` and
  `EnvelopeContract.Tests.ps1` remain green for the new wrappers (zero
  raw throws, `[CmdletBinding()]`, `Findings=@()`/`Errors=@()` envelope).
- `tests/integration/FixtureMode.Tests.ps1` continues to pass once a
  graph tool is enabled with its fixture present.

## 5. Roadmap

| Phase | Outcome | Depends on |
| --- | --- | --- |
| R0 Spike + RFC | This document; manifest schema delta; CA JSON schema; sample fixtures; legal note on read-only stance. | nothing |
| R1 Foundation + worked example | Schema enum widenings (`ConditionalAccessPolicy`, `NamedLocation`, `OnPremUser`, `OnPrem` platform, six new edge relations); `Canonicalize.ps1` cases; manifest pre-registration of full family; `conditional-access-graph` wrapper + normalizer + fixture + Pester. | R0 |
| R2 OSS / standard tools | Wrappers + normalizers + tests for `azurehound`, `pim-graph`, `roadrecon`, `graphrunner`. One PR per tool. | R1 |
| R3 Commercial Azure-native + ingest helper | Wrappers for `entra-permissions-mgmt` and `bloodhound-ce` (Neo4j ingest helper). | R1 |
| R4 Commercial gated | Wrapper for `forest-druid`. Gated on env-var presence. | R3 |
| R5 Report wiring | Standard report section + executive dashboard tile + manifest-driven rendering for the eight new tools. | R2 |
| R6 Auditor profile | `Get-AuditorIdentityGraphSection`; cite-back; CIS / NIST / MCSB control mapping. | R5 + #506 |
| R7 Graph integration | Edges feed the attack-path visualizer (#428); CA exclusion + PIM-eligible paths surface end-to-end. | R5 + #428 flesh-out |
| R8 Hardening + docs | README / PERMISSIONS / CHANGELOG; rate-limit docs; opt-out flag; CI smoke against vendored fixtures. | R7 |

R2 / R3 / R4 may run in parallel after R1 ships, but each tool MUST land
in its own PR to avoid the wrapper-ratchet collision pattern called out
in `agent patterns` memory.

## 6. Risks

- Edge volume: AzureHound emits 5-50k edges in a medium tenant. Confirm
  `EntityStore.AddEdge` does not degrade O(n^2) at that scale, and add
  an edge-dedup pass before serialization in R2 if profiling shows it
  is needed.
- Throttling: Conditional Access + PIM Graph endpoints share the same
  throttle bucket as the existing identity-graph wrappers. Reuse
  `Invoke-WithRetry` and budget-spread across tenants.
- Sensitive data in CA policies: policy display names sometimes leak
  product / codename info. Run all normalizer output through
  `Remove-Credentials` and add CA-name regex coverage in R2 if a sample
  scrubbing test reveals gaps.
- ROADrecon device-code flow: requires interactive auth; unsuitable for
  unattended CI runs. R2 wrapper will refuse to prompt and skip with a
  `MissingDependency` envelope unless `-RoadreconTokenCache` points at
  a pre-warmed cache.

## 7. Out of scope

- Write operations of any kind (consistent with Reader-only invariant).
- On-prem AD collection: hybrid `OnPremShadow` edges are derived from
  the `OnPremisesSyncEnabled` flag Entra already exposes. We do not
  crawl on-prem AD.
- Graph storage rewrite: we keep `entities.json` + `edges.json` in
  `EntityStore`; BloodHound CE ingest is one-way export only.
- Offensive tooling (AADInternals, MicroBurst write-mode, Lantern):
  outside the read-only Reader posture.
