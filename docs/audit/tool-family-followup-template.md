# Per-Family Audit Follow-up Issue Template

Use this template to spawn one follow-up issue per tool family identified in
`docs/tool-output-audit.md`. The coordinator (not the audit-fidelity scaffolder)
files these issues once #432a lands.

Families and their tools:

- **azure-gov**: azgovviz, psrule, alz-queries, powerpipe
- **security**: defender-for-cloud, prowler, maester
- **k8s**: kubescape, kube-bench, trivy, falco
- **ado**: ado-connections, ado-pipelines, ado-repos-secrets, ado-consumption, ado-pipeline-correlator
- **finops**: infracost, azure-cost, azure-quota, finops, aks-karpenter-cost
- **github**: scorecard, zizmor, gh-actions-billing
- **wara**: wara, azqr
- **misc**: sentinel-coverage, sentinel-incidents, identity-correlator, identity-graph-expansion, appinsights, loadtesting, aks-rightsizing, terraform-iac, bicep-iac, gitleaks

---

## Title

`feat(audit): tool output fidelity audit (family: <FAMILY>) (#432c-<FAMILY>)`

## Labels

`squad`, `enhancement`, `data-quality`

## Body

### Scope

Family: **<FAMILY>**
Tools in scope:

- `<tool-1>`
- `<tool-2>`
- `<tool-n>`

This issue executes the per-tool fidelity audit defined in
[`docs/tool-output-audit.md`](../tool-output-audit.md) for the tools listed
above. It is one of eight parallel family audits spawned from #432a.

### Inputs

- Audit doc skeleton: `docs/tool-output-audit.md` (rows for this family).
- Sidecar template: `docs/tool-output-audit.template.json`.
- Methodology: see "Methodology" section in the audit doc.
- Foundation schema additions: PR #435 (read-only reference; do not depend on
  it landing for the audit itself, only for the downstream #432c adoption).

### Acceptance criteria for this family

- [ ] Sanitized raw, wrapper, and normalized sample fixtures committed under
      `tests/fixtures/<tool>/` for every tool in the family.
- [ ] `docs/tool-output-audit.md` rows for this family populated with real
      counts and the full dropped-fields list (no `TODO` placeholders).
- [ ] `docs/tool-output-audit.json` (created or merged) carries the populated
      structured entries for this family.
- [ ] `auditedAt` and `auditor` set on every entry for this family.
- [ ] Sanitization (`Remove-Credentials`) verified on every committed fixture.
- [ ] Pester baseline preserved (`Invoke-Pester -Path .\tests -CI` green).
- [ ] No edits to `modules/shared/Schema.ps1`, `Invoke-AzureAnalyzer.ps1`,
      `tools/tool-manifest.json`, or any normalizer in this PR (audit only).

### Out of scope

- Schema additions to `New-FindingRow` (covered by #432b after audit results
  are in).
- Normalizer code changes (covered by per-family adoption PRs in #432c-*).
- Renderer changes (covered by Track F #434).

### Cross-references

- Parent track: #432
- Audit scaffold: #432a
- Schema extension (audit-driven): #432b
- Renderer surfacing: #434
