# Azure Analyzer v3 Architecture

## ETL pipeline (7 stages)

```mermaid
flowchart LR
    Collect --> Normalize --> ValidateCanonicalize --> MergeEntityStore --> Correlate --> Enrich --> Report
```

1. **Collect** — tool plugins gather raw signals (Azure, Graph, CI/CD, cost).
2. **Normalize** — each tool maps raw output into schema v2.
3. **Validate/Canonicalize** — enforce schema, normalize IDs, deduplicate.
4. **Merge EntityStore** — combine entity metadata + findings into a dual model.
5. **Correlate** — cross-dimension relationships (identity ↔ resources, CI/CD ↔ repos).
6. **Enrich** — add computed signals (scores, deltas, trend metadata).
7. **Report** — render report-model.json into the static HTML template + Markdown.

---

## Dual data model (entities + findings)

Azure Analyzer v3 stores **entities** and **findings** separately:

- **Entities** represent real-world resources (subscription, repo, user, app).
- **Findings** are observations about entities (compliant / non-compliant).

Each finding references its owning entity by canonical `EntityId`, while entities
aggregate all observations for reporting and correlation.

---

## Plugin model (tool-manifest.json)

Tools are declared in `tools/tool-manifest.json`. Each entry describes:

- Tool name, provider, and scope (subscription, MG, tenant, repo, ADO)
- Collector script path (`modules/Invoke-{Tool}.ps1`)
- Normalizer script path (`modules/Normalize-{Tool}.ps1`)
- Required permissions/tier and prerequisites

The orchestrator loads the manifest, resolves eligible tools, and executes them
through the shared worker pool.

---

## Schema v2 overview (findings)

| Field | Type | Description |
|---|---|---|
| `Id` | string | Unique finding ID (GUID) |
| `Source` | string | Tool name (azqr, psrule, maester, scorecard, etc.) |
| `Category` | string | High-level category (Compliance, Identity, Supply Chain) |
| `Title` | string | Short finding title |
| `Severity` | string | `Critical`, `High`, `Medium`, `Low`, `Info` |
| `Compliant` | boolean | Whether the check passed |
| `Detail` | string | Human-readable context |
| `Remediation` | string | Recommended fix steps |
| `ResourceId` | string | Canonical resource/entity ID |
| `LearnMoreUrl` | string | Documentation or reference link |

Entities use a separate schema with canonical `EntityId`, type, display name,
hierarchy, and metadata for correlation.

---

## Permission tiers (Tier 0–6)

| Tier | Scope | Enables |
|---|---|---|
| 0 | Local only | Report generation from existing JSON artifacts |
| 1 | Azure Reader | Subscription-scoped resource tools |
| 2 | Management Group Reader | MG-level governance tools |
| 3 | Microsoft Graph Read | Entra ID / identity tooling |
| 4 | GitHub / ADO Read | CI/CD and supply chain tooling |
| 5 | Cost Management Read | Cost analysis and spend findings |
| 6 | Optional AI access | AI enrichment / triage workflows |

---

## File structure (v3)

```text
azure-analyzer/
├── Invoke-AzureAnalyzer.ps1
├── report-template.html
├── modules/
│   ├── Invoke-*.ps1
│   ├── Normalize-*.ps1
│   └── shared/
│       ├── WorkerPool.ps1
│       ├── Checkpoint.ps1
│       └── ...
├── tools/
│   └── tool-manifest.json
├── docs/
│   ├── ARCHITECTURE.md
│   └── CONTRIBUTING-TOOLS.md
├── tests/
│   ├── fixtures/
│   └── normalizers/
└── output/
    ├── results.json
    ├── report-model.json
    └── report.html
```

---

## Normalizers (Phase 1)

Each of the 7 tools has a dedicated normalizer function that converts raw tool output into the unified schema v2 FindingRow format.

### Normalizer responsibilities

- **Parse raw findings** — read output from tool wrapper
- **Extract resource context** — parse ARM ResourceIds to extract subscriptionId, resourceGroup, resourceType, resourceName
- **Map schema** — convert tool-specific fields into v2 fields (Source, Category, Title, Severity, Compliant, Detail, Remediation, ResourceId, LearnMoreUrl)
- **Platform/Entity mapping** — determine owning platform and entity type per tool:
  - Azure tools (azqr, PSRule, AzGovViz, ALZ Queries, WARA) → Platform: `Azure`, EntityType: `Resource`
  - Entra ID tool (Maester) → Platform: `EntraID`, EntityType: `Tenant`
  - Repository tool (Scorecard) → Platform: `GitHub`, EntityType: `Repository`
- **Return findings only** — no side effects, return array of v2-compliant findings

### Normalizer locations

| Tool | Normalizer | Entity Type |
|---|---|---|
| azqr | `modules/normalizers/Normalize-Azqr.ps1` | Resource |
| PSRule | `modules/normalizers/Normalize-PSRule.ps1` | Resource |
| AzGovViz | `modules/normalizers/Normalize-AzGovViz.ps1` | Resource |
| ALZ Queries | `modules/normalizers/Normalize-AlzQueries.ps1` | Resource |
| WARA | `modules/normalizers/Normalize-Wara.ps1` | Resource |
| Maester | `modules/normalizers/Normalize-Maester.ps1` | Tenant |
| Scorecard | `modules/normalizers/Normalize-Scorecard.ps1` | Repository |

### Manifest-driven invocation

The orchestrator loads `tools/tool-manifest.json`, which specifies the normalizer path for each tool. After a tool collector returns `Findings`, the manifest entry's `normalizer` script is invoked to transform findings into v2 format before they enter the entity store pipeline.

---

- **Collectors never throw:** each wrapper returns `Source`, `Status`, `Message`, and `Findings`.
- **Worker pool isolation:** one tool failure does not stop others.
- **Errors are captured:** orchestrator records failures in `errors.json`.
- **Exit codes:** CI/CD uses 0–3 exit codes (success, policy violation, partial failure, total failure).
- **Checkpoint/resume:** tool results are serialized per scope for long-running scans.
