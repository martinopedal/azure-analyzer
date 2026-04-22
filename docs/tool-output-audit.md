# Tool output audit (Track D / #432a)

This catalog documents the tool-output fidelity audit for Track D, with concrete field coverage across raw tool output, wrapper output, and normalized `FindingRow` output.

## FindingRow additions tracked from #432b

Per-tool coverage below explicitly tracks these additive `FindingRow`-level fields:

- `Pillar`
- `Impact`
- `Effort`
- `DeepLinkUrl`
- `RemediationSnippets`
- `EvidenceUris`
- `BaselineTags`
- `ScoreDelta`
- `MitreTactics`
- `MitreTechniques`
- `EntityRefs`
- `ToolVersion`

## Audited tools (wave 1)

| Tool | Family | Raw findings | Wrapper findings | Normalized findings | Wrapper fields (sample) | Normalized fields (sample) | Dropped from wrapper in normalizer | #432b additions observed in wrapper |
| --- | --- | ---:| ---:| ---:| ---:| ---:| --- | --- |
| `azure-quota` | Azure | 1 | 1 | 1 | 21 | 47 | _none_ | `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `EvidenceUris`, `EntityRefs`, `ScoreDelta`, `ToolVersion` |
| `ado-connections` | Azure DevOps | 3 | 3 | 3 | 26 | 37 | `AdoOrg`, `AdoProject`, `ConnectionId`, `ConnectionType`, `AuthScheme`, `AuthMechanism`, `IsShared` | `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion` |
| `zizmor` | GitHub | 3 | 3 | 3 | 21 | 37 | _none_ | `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTechniques`, `EntityRefs`, `ToolVersion` |

## Fixture set used for this audit

- `tests/fixtures/azure-quota/raw-sample.json`
- `tests/fixtures/azure-quota/wrapper-sample.json`
- `tests/fixtures/azure-quota/normalized-sample.json`
- `tests/fixtures/ado-connections/raw-sample.json`
- `tests/fixtures/ado-connections/wrapper-sample.json`
- `tests/fixtures/ado-connections/normalized-sample.json`
- `tests/fixtures/zizmor/raw-sample.json`
- `tests/fixtures/zizmor/wrapper-sample.json`
- `tests/fixtures/zizmor/normalized-sample.json`

All fixtures above were sanitized with `Remove-Credentials` before commit.
