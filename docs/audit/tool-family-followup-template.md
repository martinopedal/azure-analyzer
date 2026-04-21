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
- Foundation hooks: PR #435 lands schema HOOKS only (no FindingRow field
  names). The audit runs in parallel with #435 and does not depend on it
  merging. Field names produced here feed #432b, which lands post-#435.

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

- Schema hooks (covered by #435; lands in parallel, no field names).
- Named FindingRow field additions (covered by #432b, post-#435 merge, named
  by the audit results this PR produces).
- Normalizer code changes (covered by per-family adoption PRs in #432c-*,
  post-#432b merge).
- Renderer changes (covered by Track F #434).

### Cross-references

- Parent track: #432
- Audit scaffold: #432a (parallel with #435)
- Foundation hooks: #435
- Schema field-name additions (audit-driven): #432b
- Renderer surfacing: #434
