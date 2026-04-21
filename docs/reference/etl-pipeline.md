# ETL Pipeline: From Raw Tools to Unified Schema

**One sentence**: Wrappers collect raw tool output (v1 envelope), normalizers transform to Schema 2.2 FindingRow (v2), and the orchestrator deduplicates into entity-centric records (v3 entities).

## Flow Diagram

```
Raw Tool Output
  ├─ stdout (JSON, SARIF, structured log, etc.)
  └─ metadata (tool version, exit code, runtime, warnings)
       |
       v
Wrapper Module (Invoke-*.ps1)
  ├─ Invokes the tool
  ├─ Captures output + stderr
  ├─ Validates exit code
  └─ Emits v1 Envelope (standard JSON shape)
       |
       v
v1 Envelope (Standardized)
  {
    "guid": "wrapper-run-id",
    "source": "tool-name",
    "compliant": false,
    "detail": "number of findings and error context",
    "findings": [ array of raw tool findings ],
    "timestamp": "ISO8601"
  }
       |
       v
Normalizer Module (Normalize-*.ps1)
  ├─ Parses v1 envelope
  ├─ Maps raw fields to Schema 2.2 slots
  ├─ Applies severity normalization
  ├─ Decomposes ARM IDs to entity references
  └─ Calls New-FindingRow to build v2 rows
       |
       v
v2 FindingRow (Schema 2.2)
  ├─ 32 fields (RuleId, Title, Severity, ...)
  ├─ Normalized enums (severity, entity types, frameworks)
  ├─ Metadata (Pillar, Impact, Effort, evidence URIs, ...)
  └─ Optional fields (MITRE tags, remediation snippets, ...)
       |
       v
Orchestrator + EntityStore
  ├─ Reads all v2 rows
  ├─ Groups by canonical entity ID
  ├─ Deduplicates cross-tool findings
  ├─ Merges metadata from all findings per entity
  └─ Emits v3 Entities + results.json (legacy)
       |
       v
Output Files
  ├─ results.json (v1 findings, legacy)
  ├─ entities.json (v3 deduplicated entities)
  ├─ report.html (interactive findings browser)
  └─ report.md (GitHub-flavored markdown)
```

---

## What Each Layer Does

### Layer 1: Wrapper (v1 Envelope)

**Purpose**: Run the tool, capture output, wrap it in a standard shape.

**Responsibilities**:
1. Invoke the tool with the right parameters.
2. Capture stdout, stderr, exit code.
3. Parse tool output (JSON, SARIF, CSV, etc.).
4. Build the v1 envelope: a standard JSON object with `guid`, `source`, `compliant`, `detail`, `findings` array.
5. Return the envelope (success or error status).

**Contract**:
```json
{
  "guid": "run-id-guid",
  "source": "tool-name",
  "compliant": true or false,
  "detail": "human-readable summary",
  "findings": [ ... raw findings from tool ... ],
  "timestamp": "2026-04-23T...",
  "status": "Success" or "Partial" or "Failed"
}
```

**Example**: `modules/Invoke-Azqr.ps1` runs `azqr scan -...` and wraps the JSON output in a v1 envelope.

---

### Layer 2: Normalizer (v2 FindingRow)

**Purpose**: Transform raw findings to the unified Schema 2.2 format.

**Responsibilities**:
1. Read the v1 envelope.
2. For each raw finding, map fields to Schema 2.2 slots.
3. Normalize severity strings (azqr says "High", gitleaks says "high", both become "High").
4. Decompose resource identifiers into canonical entity references (e.g., Azure Resource ID → entity type + resource name).
5. Call `New-FindingRow` to build each v2 row (validates required fields, rejects invalid rows).
6. Emit an array of v2 FindingRow objects.

**Contract**: v2 FindingRow has 32 fields (see [schema-2.2.md](schema-2.2.md)):
```
RuleId, Title, Severity, Category, EntityType, EntityId, Platform, 
Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets,
EvidenceUris, BaselineTags, MitreTactics, MitreTechniques, EntityRefs,
ToolVersion, Status, [optional fields...]
```

**Example**: `modules/normalizers/Normalize-Azqr.ps1` reads azqr raw findings and maps `RecommendationId` → `RuleId`, `ResourceGroupName` + `ResourceName` → entity reference, `Severity` enum → normalized severity, etc.

<details><summary><b>Per-tool field mapping examples</b></summary>

**Azqr Mapping**:
- Raw `RecommendationId` → v2 `RuleId`
- Raw `Impact` → v2 `Impact`
- Raw `ResourceGroupName`, `ResourceName` → v2 `EntityRefs` (ARM ID construction)
- Raw `Severity` (string) → v2 `Severity` (normalized enum: Critical, High, Medium, Low, Info)

**Gitleaks Mapping**:
- Raw `RuleID` → v2 `RuleId`
- Raw `Match` → v2 `Title`
- Raw `Secret` → v2 `EntityId` (commit SHA)
- Fixed `Severity='Critical'` for cloud credentials
- Raw `File` → v2 `EntityRefs` (repo-relative path)

**Trivy Mapping**:
- Raw `VulnerabilityID` (CVE) → v2 `RuleId`
- Raw `Title` → v2 `Title`
- Raw `Severity` → v2 `Severity` (CVSS7.5 → High, etc.)
- Raw `CVSS` score → v2 `ScoreDelta`
- Raw `References` → v2 `EvidenceUris`
- Raw `FixedVersion` → v2 `RemediationSnippets`

</details>

---

### Layer 3: Orchestrator + EntityStore (v3 Entities)

**Purpose**: Deduplicate findings across tools and group by entity.

**Responsibilities**:
1. Read all v2 FindingRow objects from all normalizers.
2. Group findings by canonical entity ID (subscription, resource, repository, etc.).
3. For each entity, merge metadata from all findings (frameworks, tags, evidence, etc.).
4. Emit `entities.json` (v3 format, deduplicated).
5. Emit `results.json` (legacy v1 findings for back-compat).

**Entity Store Output (`entities.json`)**:
```json
[
  {
    "id": "tenant:12345",
    "type": "Tenant",
    "platform": "Azure",
    "findings": [
      { "ruleId": "...", "severity": "High", "tool": "azqr" },
      { "ruleId": "...", "severity": "High", "tool": "psrule" }
    ],
    "aggregates": { "critical": 0, "high": 2, "medium": 1, ... }
  },
  ...
]
```

**Example**: Two tools (azqr and psrule) both find the same subscription has a security misconfiguration. EntityStore groups both findings under the subscription entity, deduplicates by rule, and emits one entity record with two findings.

<details><summary><b>Deduplication strategy</b></summary>

1. **Canonical entity ID**: Every finding has an `EntityId` (resource ID, repository path, subscription GUID, etc.). Two findings with the same canonical ID refer to the same entity.
2. **RuleId scope**: Within an entity, findings are grouped by `RuleId`. If two tools report the same `RuleId` on the same entity, only one row is kept (first seen wins) with tool cross-references in `EntityRefs`.
3. **Metadata merging**: Tags, frameworks, evidence URIs from all findings on an entity are merged into the entity record so one entity can carry insights from multiple tools.

</details>

---

## Reports

**HTML Report** (`report.html`):
- Reads `entities.json` and `results.json`.
- Renders an interactive tree: platform → tool → resource → findings.
- Framework heatmap, severity breakdown, CSV export.
- Persists expand/collapse state in browser local storage.

**Markdown Report** (`report.md`):
- Reads `entities.json` and `results.json`.
- Renders a flat findings list with framework badges, severity emoji, deep links.
- Collapsible evidence and remediation sections.
- Git-friendly (100-char lines, no HTML).

---

## Error Handling

<details><summary><b>What happens if a tool fails?</b></summary>

1. **Wrapper catches error**: Tool invocation throws or exits nonzero.
2. **Wrapper emits error status**: v1 envelope has `status='Failed'` and `detail` describes the error.
3. **Orchestrator skips normalizer**: If wrapper status is not `Success`, the normalizer is not run.
4. **Findings are not emitted**: No v2 or v3 rows for that tool's run.
5. **Error is logged**: stderr goes to `sanitizer` which scrubs credentials before logging.

**Result**: One failed tool does not crash the whole run. Other tools' findings are emitted normally.

</details>

<details><summary><b>What happens if a finding is invalid?</b></summary>

1. **Normalizer calls New-FindingRow**: If required fields are missing or types are wrong, `New-FindingRow` returns `$null`.
2. **Normalizer filters nulls**: `$findings = $findings | Where-Object { $_ }` removes invalid rows.
3. **Orchestrator counts skipped**: Normalizer logs how many rows were dropped.

**Result**: Invalid findings are silently dropped (logged but not emitted). This prevents report generation failures.

</details>

---

## Versioning and Stability

- **v1 Envelope**: Stable, used by all wrappers. Changes require migration across all wrappers.
- **v2 FindingRow**: Schema 2.2, locked. New fields are optional; old normalizers don't break.
- **v3 Entities**: New, entity-centric dedup model. Back-compat layer emits v1 `results.json` so old consumers still work.

---

See [schema-2.2.md](schema-2.2.md) for the complete FindingRow specification and [../architecture/normalizer-contract.md](../architecture/normalizer-contract.md) for the normalizer contract and testing patterns.
