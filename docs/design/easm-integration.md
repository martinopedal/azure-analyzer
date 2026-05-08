# EASM (External Attack Surface Management) Integration

Status: In Review
Owners: squad
Related: #428 (attack-path visualizer), #506 (Track F auditor report), #432a / #491 (Track D normalizer fields)

## 1. Problem statement

`azure-analyzer` is inside-out: it inspects what we own in Azure, Entra,
Azure DevOps, and GitHub. EASM (External Attack Surface Management) flips
that perspective and asks "what does an attacker see from the outside?".

Concretely, we need to discover:

- Internet-reachable IPs and ports for the assets we own.
- Subdomains that resolve into our cloud footprint, including abandoned
  CNAMEs that are subdomain-takeover candidates.
- TLS certificates issued for our domains via certificate transparency.
- Typosquat or homoglyph domains targeting our brand.
- Findings already produced by Microsoft Defender EASM when the customer
  has it provisioned.

The output must correlate back to the existing `AzureResource` /
`Tenant` / `Repository` entities in the v3 entity store so the auditor
report (Track F) and attack-path visualizer (Track A) can extend through
the perimeter.

## 2. Constraints

- Cloud-first: tools target remote DNS, certificate transparency, and
  internet-wide scanners. No local artefacts are required.
- Reader-only: no write scopes anywhere. Consistent with the repo-wide
  permission invariant in `PERMISSIONS.md`.
- HTTPS-only and host allow-listed: outbound traffic to vendor APIs must
  pass the `RemoteClone` / `Installer` allow-list policy.
- Secret-safe: API keys (Shodan, Censys, Defender EASM) are read from the
  environment only and scrubbed by `Remove-Credentials` before any
  finding, log, or error is written to disk.
- Passive by default: active probing (port scans, brute-force subdomain
  enumeration) is opt-in via `-EnableActiveProbe`. This keeps the tool
  legally clean for assets the operator does not own.
- Schema-additive: changes to `Schema.ps1` must remain back-compatible
  with the existing FindingRow contract (v2.2).

## 3. Vendor matrix

| Tool | License | Auth | Why we want it | Scope |
| --- | --- | --- | --- | --- |
| Shodan | Commercial (free tier 100 q/mo) | API key | Banner-grabbing internet-wide scan; canonical "what services answer on our IPs" source | tenant + custom IP/domain seeds |
| Censys Search v2 | Free + paid | API ID + secret | Cert transparency + host scan; richer TLS/cert pivots than Shodan | tenant |
| OWASP Amass (passive mode) | Apache-2.0 | none / optional API keys | Subdomain enumeration via 60+ sources; zero-cost backbone | tenant |
| Subfinder (ProjectDiscovery) | MIT | optional API keys | Faster passive subdomain enum, complements Amass | tenant |
| httpx (ProjectDiscovery) | MIT | none | Probes discovered hosts; status, title, tech stack, TLS | tenant |
| DNSTwist | Apache-2.0 | none | Typosquat / homoglyph detection for brand domains | tenant |
| Microsoft Defender EASM (optional, gated) | Azure paid SKU | Azure AD | First-party; consume existing workspace findings if provisioned | subscription |

Explicitly deferred: SecurityTrails, BinaryEdge, RiskIQ Community
(retired), Zoomeye (premium-only with no free tier worth wrapping); ZAP
and Nuclei (out of scope; those are DAST, not EASM).

## 4. Acquisition stance

1. Passive sources by default. Active probing is opt-in.
2. Cloud-first: remote DNS, certificate transparency, internet-wide
   scanners. No local network scans.
3. Seed input priority order:
   1. Azure ARG: public IPs, Front Door / App Gateway / API Management
      frontends, public Storage endpoints, AKS load balancers (already
      discoverable via the existing ARG queries).
   2. Entra: verified domains via Microsoft Graph
      (`Domain.Read.All`, already in the manifest).
   3. Operator-supplied `--EasmSeedFile` JSON:
      `{ domains:[], ips:[], cidrs:[], asns:[] }`.

## 5. Architecture

### 5.1 Manifest registration

Add seven entries to `tools/tool-manifest.json` under a new
`provider: "easm"` family. Names must remain alphabetically sorted to
satisfy `tests/manifest/Manifest.Sorted.Tests.ps1`.

| Tool | scope | install.kind | enabled (initial) |
| --- | --- | --- | --- |
| amass | tenant | cli | false (R2) |
| censys | tenant | psmodule | false (R3) |
| defender-easm | subscription | none | false (R4) |
| dnstwist | tenant | cli | true (worked example, R2) |
| httpx | tenant | cli | false (R2) |
| shodan | tenant | none | false (R3) |
| subfinder | tenant | cli | false (R2) |

Tools ship `enabled: false` until their wrapper, normalizer, fixture, and
tests land. The DNSTwist wrapper ships with this PR and is the
worked example that validates the foundation end-to-end.

### 5.2 New shared modules

- `modules/shared/EasmSeed.ps1` exposes `Get-EasmSeed`, which builds the
  seed bundle from operator overrides (file or in-memory hashtable) plus
  optional ARG / Graph augmentation. Output is a normalised seed object
  with a stable hash for cache invalidation.
- `modules/shared/EasmCorrelator.ps1` exposes `Resolve-EasmEntity`,
  which maps a discovered IP / hostname back to a canonical
  `AzureResource` ID using the public-IP and Front Door inventories
  already in `entities.json`. Uncorrelated assets fall back to
  `EntityType=ExternalAsset`.

### 5.3 Schema additions

- `Schema.ps1` `$script:EntityTypes` gains `'ExternalAsset'`.
- `Schema.ps1` `$script:Platforms` gains `'External'`.
- `Get-PlatformForEntityType` maps `ExternalAsset -> External`.
- `Get-PlatformForEntityType`'s `[ValidateSet(...)]` is widened to
  match the enum (back-compatible additive change).

These additions are dual-read safe: existing callers continue to work
unchanged because `[ValidateSet]` only widens.

### 5.4 Wrappers and normalizers

Each wrapper lives at `modules/Invoke-<Tool>.ps1`. Each normalizer lives
at `modules/normalizers/Normalize-<Tool>.ps1`. Wrapper contract:

- Dot-source `Sanitize.ps1`, `Errors.ps1`, `New-WrapperEnvelope.ps1`,
  `Retry.ps1`, `CliTimeout.ps1` with inline fallback stubs (matches the
  established pattern documented in the wrapper memory).
- `[CmdletBinding()]` declared on every wrapper.
- HTTPS-only outbound; the EASM host allow-list is documented in
  PERMISSIONS.md.
- 300 s `Invoke-WithTimeout` per external call.
- `Invoke-WithRetry` on transient REST failures.
- Returns a v1 envelope (`SchemaVersion: 1.0`, `Findings`, `Errors`).

Normalizer contract:

- Converts the v1 envelope to v2 `FindingRow` records via
  `New-FindingRow`.
- Severity maps onto the canonical 5-level enum.
- Uses `Resolve-EasmEntity` to assign `EntityId` /
  `EntityType` / `Platform` (`AzureResource` when correlated, otherwise
  `ExternalAsset` + `External`).
- Sets `Pillar=Exposure` and `Domain=ExternalAttackSurface`.

### 5.5 Severity rubric

Initial mapping. Per-tool overrides may refine these.

| Indicator | Severity |
| --- | --- |
| RDP (3389), SMB (445), MSSQL (1433), telnet (23), Redis (6379), MongoDB (27017) open to Internet | High |
| HTTP/HTTPS service exposed (expected in many cases) | Info / Low |
| Expired TLS certificate | Medium |
| TLS certificate expiring within 30 days | Low |
| Self-signed cert on production domain | Medium |
| Subdomain takeover candidate (orphan CNAME) | High |
| Typosquat / homoglyph domain registered to a third party | Medium |
| Defender EASM Critical / High / Medium / Low / Info | passthrough |

### 5.6 Report integration

- Standard HTML / MD report (`New-HtmlReport.ps1`, `New-MdReport.ps1`)
  gains an "External Attack Surface" section with an open-ports heatmap
  (host x port), expiring / expired certificate table, subdomain
  takeover candidates, and typosquat domains. Rendering reuses the
  existing manifest-driven tool-section loop; the only new render code
  is the heatmap component.
- Auditor report (Track F, #506) gains
  `Get-AuditorAttackSurfaceSection`, slotted between the Resilience and
  Policy Coverage sections. Cited via `SourceQueryHash` per the
  Track F provenance contract.
- Executive dashboard (`New-ExecDashboard.ps1`) gains a KPI tile:
  "Internet-exposed assets / High-severity exposures /
  Cert expiring 30 d / Typosquat domains".
- Entity store: exposed assets feed into the v3 graph so they appear
  in the attack-path visualizer (Track A, #428).

### 5.7 Permissions delta

| Source | New scope |
| --- | --- |
| Shodan | API key (env `SHODAN_API_KEY`) |
| Censys | API ID + secret (env `CENSYS_API_ID`, `CENSYS_API_SECRET`) |
| Microsoft Defender EASM | `Microsoft.Easm/workspaces/read` (Reader on the EASM workspace) |
| Azure ARG | already covered (Reader) |
| Entra | already covered for `Domain.Read.All` |

No write scopes anywhere, consistent with the Reader-only invariant.

### 5.8 Security invariants

All existing invariants apply unchanged:

- HTTPS-only, host allow-list extended to `api.shodan.io`,
  `search.censys.io`, `*.easm.defender.microsoft.com`.
- API keys read from environment only, scrubbed by `Remove-Credentials`
  before any persistence.
- Allow-listed package managers for installer (`pipx` for Python tools,
  `winget` / `brew` for binaries).
- `Invoke-WithTimeout` 300 s on every external call.

### 5.9 Testing

- One normalizer test per tool with a realistic fixture in
  `tests/fixtures/<tool>-output.json`.
- One wrapper test per tool covering: success path, transient retry,
  timeout, sanitization of API key from error output.
- One shared-module test per new shared file (`EasmSeed`,
  `EasmCorrelator`).
- `WrapperConsistencyRatchet.Tests.ps1` and
  `EnvelopeContract.Tests.ps1` must remain green for the new wrappers.
- `tests/integration/FixtureMode.Tests.ps1` continues to pass when the
  EASM tools are enabled with their fixtures present.

## 6. Roadmap

| Phase | Outcome | Depends on |
| --- | --- | --- |
| R0 Spike + RFC | This document; manifest schema delta; seed format; sample fixtures from each vendor; legal note on passive vs active. | nothing |
| R1 Foundation | `EasmSeed`, `EasmCorrelator`, `ExternalAsset` entity type, `External` platform, sanitize patterns, host allow-list update, allow-list installer entries, manifest entries (disabled). | R0 |
| R2 Passive tools | Wrappers + normalizers + tests for Amass, Subfinder, httpx, DNSTwist (zero-cost, no API keys). | R1 |
| R3 Commercial tools | Wrappers + normalizers for Shodan and Censys; key-management docs; rate-limit handling. Gated by env-var presence. | R1 |
| R4 First-party tool | Wrapper for Microsoft Defender EASM; consumes existing workspace findings. | R1 |
| R5 Report wiring | Standard report section + executive dashboard tile + manifest-driven rendering for the seven new tools. | R2 |
| R6 Auditor profile | `Get-AuditorAttackSurfaceSection`; cite-back; CIS / NIST / MCSB control mapping. | R5 + #506 |
| R7 Graph integration | `EXPOSES` edges feed the attack-path visualizer (#428); subdomain-takeover paths surface end-to-end. | R5 + #428 flesh-out |
| R8 Hardening + docs | README / PERMISSIONS / CHANGELOG; rate-limit docs; opt-out flag; CI smoke against vendored fixtures. | R7 |

R2 / R3 / R4 may run in parallel after R1 ships.

## 7. Risks

- Vendor API churn: mitigated by per-vendor fixtures and the fixture-mode
  integration test.
- False positives on unowned IPs: mitigated by always passing through
  `EasmCorrelator`. Uncorrelated assets are surfaced in a separate
  "unverified ownership" bucket so auditors can dismiss them.
- Legal exposure on active scans: opt-in only, with a banner in the
  operator guide and refusal to scan IPs not in the seed bundle.
- Rate limits (Shodan free tier is 100 queries / month): the wrapper
  caches results by seed-hash and refuses to re-run within 24 h unless
  `-Force` is set.

## 8. Out of scope

- Active vulnerability scanning (Nessus, OpenVAS, Nuclei).
- Web application DAST (OWASP ZAP, Burp).
- Phishing simulation or brand monitoring beyond DNS typosquatting.
- Threat intelligence feed correlation (defer to Sentinel / Defender for
  Cloud, which we already wrap).
