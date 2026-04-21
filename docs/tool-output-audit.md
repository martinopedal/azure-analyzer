# Tool Output Fidelity Audit

> Status: SKELETON (#432a). Per-tool rows are placeholders. Real fixture-based
> audits land per tool family in follow-up issues (see
> [`docs/audit/tool-family-followup-template.md`](audit/tool-family-followup-template.md)).
> Foundation schema additions (the optional FindingRow fields) land separately
> in PR #435 and are out of scope for this document.

## Why this audit exists

azure-analyzer invokes 36 underlying tools. Each tool emits richer raw output
than what currently survives the wrapper plus normalizer plus FindingRow
pipeline. This audit catalogues, per tool, exactly which fields the tool emits,
which ones we preserve at each stage, and which ones we drop. The output of the
audit is the evidence that drives the (audit-proven, not pre-speculated) schema
extensions in #432b and the per-family normalizer adoption work in #432c.

The audit is read-only. No tool runs against any real tenant as part of #432a.
Sample captures are produced family-by-family in the follow-up issues using
sanitized fixtures stored under `tests/fixtures/`.

## Methodology

For each tool the audit performs the following steps in order:

1. Run the tool against a representative target (real tenant, ADO org, repo, or
   cluster) with the smallest scope that exercises every finding type the tool
   supports. Capture the raw stdout/JSON to a sanitized fixture under
   `tests/fixtures/<tool>/raw-sample.json`.
2. Pass the same raw output through the existing wrapper and capture the v1
   envelope to `tests/fixtures/<tool>/wrapper-sample.json`. Diff the v1
   envelope against the raw fixture to enumerate fields the wrapper drops.
3. Pass the v1 envelope through the existing normalizer and capture the v2
   FindingRow output to `tests/fixtures/<tool>/normalized-sample.json`. Diff
   against the v1 envelope to enumerate fields the normalizer drops.
4. Map every surviving v1 field to its target field on the current FindingRow
   schema (`modules/shared/Schema.ps1` `New-FindingRow`). Any field that has no
   target slot is recorded as a candidate for the #432b schema extension.
5. Record the result in two places: a row in the field-coverage table below,
   and a structured entry in `docs/tool-output-audit.template.json` (copied to
   `docs/tool-output-audit.json` once the family audit is done).
6. Sanitize all captured fixtures via `modules/shared/Sanitize.ps1`
   `Remove-Credentials` before committing.

## Field-coverage table

Legend:

- **Wrapper Preserves**: count of raw fields surfaced into the v1 envelope, or
  `TODO` when not yet sampled.
- **Normalizer Preserves**: count of v1 fields surfaced into v2 FindingRow.
- **New FindingRow Maps**: candidate target fields proposed by #432b.
- **Dropped Fields**: list of raw fields that never reach the FindingRow.
- **Notes**: short qualitative observations (e.g. "tool emits CIS controls",
  "tool emits remediation script").

### Family: azure-gov (4 tools)

| Tool        | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|-------------|-------------------|----------------------|---------------------|----------------|-------|
| azgovviz    | TODO: capture sample | TODO | TODO | TODO | TODO |
| psrule      | TODO: capture sample | TODO | TODO | TODO | TODO |
| alz-queries | TODO: capture sample | TODO | TODO | TODO | TODO |
| powerpipe   | TODO: capture sample | TODO | TODO | TODO | TODO |

### Family: security (3 tools)

| Tool               | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|--------------------|-------------------|----------------------|---------------------|----------------|-------|
| defender-for-cloud | TODO: capture sample | TODO | TODO | TODO | TODO |
| prowler            | TODO: capture sample | TODO | TODO | TODO | TODO |
| maester            | TODO: capture sample | TODO | TODO | TODO | TODO |

### Family: k8s (4 tools)

| Tool       | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|------------|-------------------|----------------------|---------------------|----------------|-------|
| kubescape  | TODO: capture sample | TODO | TODO | TODO | TODO |
| kube-bench | TODO: capture sample | TODO | TODO | TODO | TODO |
| trivy      | TODO: capture sample | TODO | TODO | TODO | TODO |
| falco      | TODO: capture sample | TODO | TODO | TODO | TODO |

### Family: ado (5 tools)

| Tool                    | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|-------------------------|-------------------|----------------------|---------------------|----------------|-------|
| ado-connections         | TODO: capture sample | TODO | TODO | TODO | TODO |
| ado-pipelines           | TODO: capture sample | TODO | TODO | TODO | TODO |
| ado-repos-secrets       | TODO: capture sample | TODO | TODO | TODO | TODO |
| ado-consumption         | TODO: capture sample | TODO | TODO | TODO | TODO |
| ado-pipeline-correlator | TODO: capture sample | TODO | TODO | TODO | TODO |

### Family: finops (5 tools)

| Tool             | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|------------------|-------------------|----------------------|---------------------|----------------|-------|
| infracost        | TODO: capture sample | TODO | TODO | TODO | TODO |
| azure-cost       | TODO: capture sample | TODO | TODO | TODO | TODO |
| azure-quota      | TODO: capture sample | TODO | TODO | TODO | TODO |
| finops           | TODO: capture sample | TODO | TODO | TODO | TODO |
| aks-karpenter-cost | TODO: capture sample | TODO | TODO | TODO | TODO |

### Family: github (3 tools)

| Tool               | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|--------------------|-------------------|----------------------|---------------------|----------------|-------|
| scorecard          | TODO: capture sample | TODO | TODO | TODO | TODO |
| zizmor             | TODO: capture sample | TODO | TODO | TODO | TODO |
| gh-actions-billing | TODO: capture sample | TODO | TODO | TODO | TODO |

### Family: wara (2 tools)

| Tool | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|------|-------------------|----------------------|---------------------|----------------|-------|
| wara | TODO: capture sample | TODO | TODO | TODO | TODO |
| azqr | TODO: capture sample | TODO | TODO | TODO | TODO |

### Family: misc (10 tools)

| Tool                       | Wrapper Preserves | Normalizer Preserves | New FindingRow Maps | Dropped Fields | Notes |
|----------------------------|-------------------|----------------------|---------------------|----------------|-------|
| sentinel-coverage          | TODO: capture sample | TODO | TODO | TODO | TODO |
| sentinel-incidents         | TODO: capture sample | TODO | TODO | TODO | TODO |
| identity-correlator        | TODO: capture sample | TODO | TODO | TODO | TODO |
| identity-graph-expansion   | TODO: capture sample | TODO | TODO | TODO | TODO |
| appinsights                | TODO: capture sample | TODO | TODO | TODO | TODO |
| loadtesting                | TODO: capture sample | TODO | TODO | TODO | TODO |
| aks-rightsizing            | TODO: capture sample | TODO | TODO | TODO | TODO |
| terraform-iac              | TODO: capture sample | TODO | TODO | TODO | TODO |
| bicep-iac                  | TODO: capture sample | TODO | TODO | TODO | TODO |
| gitleaks                   | TODO: capture sample | TODO | TODO | TODO | TODO |

Total tools accounted for: 36 (matches the enabled set in
`tools/tool-manifest.json`).

## Machine-readable sidecar

`docs/tool-output-audit.template.json` carries the same data in structured
form. Each family-audit PR copies the template to
`docs/tool-output-audit.json` (or merges into it) and fills in the per-tool
arrays. Renderers and downstream tooling consume the JSON; the markdown table
above is the human-friendly view.

## Cross-references

- Issue #432 : parent track (audit + extension + adoption + render).
- Issue #432a : this scaffold.
- Issue #432b : schema extension, gated on audit results.
- Issue #432c-* : per-family normalizer adoption PRs.
- PR #435 : foundation FindingRow schema additions (out of scope here).
- Track F #434 : renderer surfacing of new fields.
