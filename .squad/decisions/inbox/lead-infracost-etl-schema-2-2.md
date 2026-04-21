# Lead decision - infracost Schema 2.2 ETL

- Issue: #312
- Scope: `Invoke-Infracost.ps1` + `Normalize-Infracost.ps1`
- Decision: emit v1 `ToolSummary` and carry Schema 2.2 cost metadata end-to-end.
- Mapping:
  - `Pillar=Cost` for all findings.
  - `Impact` derived from finding monthly cost as percent of project total.
  - `Effort` derived from Terraform resource type complexity buckets.
  - `ScoreDelta` mapped from monthly baseline diff (`DiffMonthlyCost`).
  - `Frameworks` emits `{ kind: WAF, controlId: Cost }`.
- Evidence:
  - Wrapper stores breakdown payload path as `EvidenceUris` and propagates tool version (`infracost --version`).
  - Normalizer maps all fields through `New-FindingRow` v2.2 params.
- Validation:
  - Targeted tests: wrapper + normalizer green.
  - Full Pester suite green.
