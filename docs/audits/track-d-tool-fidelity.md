# Track D — tool output fidelity audit (#432)

> Status: **draft**, queued behind the 8h close plan
> ([`.squad/decisions/inbox/lead-8h-close-plan-2026-04-22.md`](../../.squad/decisions/inbox/lead-8h-close-plan-2026-04-22.md)).
> Wave-1 audit lives in [`docs/tool-output-audit.md`](../tool-output-audit.md) (#432a, merged in PR #465).
> This doc extends the audit to **all 36 normalizers** and proposes the first three enrichment patches (#432b).

## 1. Methodology

For every wrapper in `modules/Invoke-*.ps1` we check whether the corresponding
`modules/normalizers/Normalize-*.ps1` carries the **schema 2.2 additive surface**
through to `New-FindingRow`. The 12 audit dimensions are the additive fields
introduced by #299 and tracked by #432:

| Dimension              | Vendor-side equivalents (representative)                                          |
| ---------------------- | --------------------------------------------------------------------------------- |
| `Pillar`               | WAF pillar / OpenSSF category / WARA pillar                                       |
| `Impact`               | Defender `metadata.userImpact`, Maester `severityScore`, Scorecard score bucket   |
| `Effort`               | Defender `metadata.implementationEffort`, kubescape control complexity            |
| `DeepLinkUrl`          | Portal blade URL, kubescape `hub.armosec.io/docs/<control>`                       |
| `RemediationSnippets`  | Bicep / Terraform / az-cli code blocks parsed from `Remediation`                  |
| `EvidenceUris`         | LearnMoreUrl, raw record ref, scorecard CheckDetails URLs, Maester proof links    |
| `BaselineTags`         | PSRule baseline (`Azure.GA_2024_06`), Trivy DB version, scorecard CLI version     |
| `ScoreDelta`           | Defender secure-score delta, scorecard `10 - score`, infracost `monthlyCost`      |
| `MitreTactics`         | Defender `metadata.threats`, kubescape MITRE mapping                              |
| `MitreTechniques`      | Same source, T-numbers                                                            |
| `EntityRefs`           | Subscription / repo-org / tenant scope to support cross-source folding            |
| `ToolVersion`          | `azqr --version`, `gitleaks version`, `scorecard version: vX.Y.Z`                 |

Detection is performed against the live source via three patterns: explicit
`-Dim` named parameter on `New-FindingRow`, splat-key (`Dim = ...`) inside a
splatted hashtable, and pass-through normalizers that mutate `f.Dim` directly.
A field is counted as **carried** if any of the three is present.

## 2. Coverage matrix (36 wrappers x 12 dimensions)

`Y` = field is plumbed through. `.` = field is dropped (left at the
zero-value default by `New-FindingRow`).

| Normalizer              | Pil | Imp | Eff | DL  | RS  | EU  | BT  | SD  | MTac | MTec | ER  | TV  | Missing |
| ----------------------- | --- | --- | --- | --- | --- | --- | --- | --- | ---- | ---- | --- | --- | ------: |
| AzGovViz                | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y    | Y    | Y   | Y   |       0 |
| Falco                   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y    | Y    | Y   | Y   |       0 |
| ADOPipelineSecurity     | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | Y    | Y    | Y   | Y   |       1 |
| Azqr                    | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | Y    | Y    | Y   | Y   |       1 |
| IaCTerraform            | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | Y    | Y    | Y   | Y   |       1 |
| IdentityCorrelation     | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | Y    | Y    | Y   | Y   |       1 |
| Powerpipe               | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | Y    | Y    | Y   | Y   |       1 |
| Zizmor                  | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | Y    | Y    | Y   | Y   |       1 |
| AdoConsumption          | Y   | Y   | Y   | Y   | .   | Y   | Y   | Y   | .    | .    | Y   | Y   |       3 |
| ADOConnections          | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | .    | .    | Y   | Y   |       3 |
| ADOPipelineCorrelator   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | .    | .    | Y   | Y   |       3 |
| ADORepoSecrets          | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | .    | .    | Y   | Y   |       3 |
| AksKarpenterCost        | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .    | .    | Y   | Y   |       2 |
| AksRightsizing          | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .    | .    | Y   | Y   |       2 |
| AlzQueries              | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | .    | .    | Y   | Y   |       3 |
| AppInsights             | Y   | Y   | Y   | Y   | .   | Y   | Y   | Y   | .    | .    | Y   | Y   |       3 |
| AzureCost               | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .    | .    | Y   | Y   |       2 |
| AzureLoadTesting        | Y   | Y   | Y   | Y   | .   | Y   | Y   | Y   | .    | .    | Y   | Y   |       3 |
| AzureQuotaReports       | Y   | Y   | Y   | Y   | .   | Y   | .   | Y   | .    | .    | Y   | Y   |       4 |
| DefenderForCloud        | Y   | Y   | Y   | Y   | .   | Y   | .   | Y   | Y    | Y    | .   | Y   |       3 |
| FinOpsSignals           | Y   | Y   | Y   | Y   | Y   | Y   | .   | Y   | .    | .    | Y   | Y   |       3 |
| GhActionsBilling        | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .    | .    | Y   | Y   |       2 |
| Gitleaks                | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .   | .    | .    | Y   | Y   |       3 |
| IaCBicep                | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .    | .    | Y   | Y   |       2 |
| IdentityGraphExpansion  | Y   | Y   | Y   | Y   | .   | .   | .   | .   | Y    | Y    | Y   | Y   |       4 |
| Infracost               | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .    | .    | Y   | Y   |       2 |
| KubeBench               | Y   | Y   | .   | Y   | Y   | .   | Y   | .   | .    | .    | Y   | Y   |       5 |
| **Kubescape**           | Y   | .   | .   | .   | .   | Y   | Y   | .   | Y    | Y    | .   | Y   |   **6** |
| Maester                 | Y   | .   | .   | Y   | Y   | Y   | Y   | .   | Y    | Y    | Y   | Y   |       3 |
| Prowler                 | Y   | .   | .   | Y   | Y   | Y   | Y   | .   | Y    | Y    | .   | Y   |       4 |
| **PSRule**              | Y   | .   | .   | Y   | Y   | .   | Y   | .   | .    | .    | .   | Y   |   **7** |
| **Scorecard**           | Y   | .   | .   | Y   | Y   | Y   | Y   | .   | .    | .    | .   | Y   |   **6** |
| SentinelCoverage        | Y   | .   | .   | Y   | .   | .   | .   | .   | Y    | Y    | Y   | Y   |       6 |
| SentinelIncidents       | Y   | .   | .   | Y   | .   | Y   | .   | .   | Y    | Y    | Y   | Y   |       5 |
| Trivy                   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | Y   | .    | .    | Y   | Y   |       2 |
| WARA                    | Y   | Y   | Y   | Y   | Y   | .   | Y   | .   | .    | .    | Y   | Y   |       4 |

The three normalizers selected for the first enrichment wave (bolded) are
PSRule, Kubescape, and Scorecard — they each drop >=6 dimensions while emitting
high-volume findings to prominent UX surfaces (Security pillar roll-ups, AKS
cluster cards, supply-chain dashboard).

## 3. Vendor-specific enrichment fields preserved in `entities.json`

| Vendor field                                   | Tool             | Carried? | Notes                                                                                |
| ---------------------------------------------- | ---------------- | -------- | ------------------------------------------------------------------------------------ |
| `recommendation.metadata.severity`             | Defender         | Yes      | Mapped to schema severity, original casing dropped                                   |
| `recommendation.metadata.threats`              | Defender         | Yes      | Plumbed through `MitreTactics`                                                       |
| `recommendation.metadata.userImpact`           | Defender         | **No**   | Could populate `Impact`; currently lost                                              |
| `recommendation.metadata.implementationEffort` | Defender         | **No**   | Could populate `Effort`; currently lost                                              |
| `severityScore` (numeric)                      | Maester          | **No**   | Could populate `ScoreDelta`; currently lost                                          |
| `cve.cvssV3`                                   | Trivy            | Partial  | Wrapper folds CVSS into `Detail` text; structured numeric not surfaced               |
| `cve.fixedVersion`                             | Trivy            | **No**   | Folded into `Remediation` text; structured field lost                                |
| `score` (0-10)                                 | Scorecard        | Partial  | Used for severity bucketing; not surfaced as `ScoreDelta` (now fixed in patch 3)     |
| `controlId` (`C-0017`)                         | Kubescape        | Yes      | Plumbed via `RuleId` and `Controls[]`                                                |
| `frameworks[].controls[]`                      | Kubescape, Prowler | Yes    | Plumbed via `Frameworks[].Controls`                                                  |
| `baselineModule` (`Azure.GA_2024_06`)          | PSRule           | Yes      | Plumbed via `BaselineTags`                                                           |
| `Recommendation` (markdown w/ fenced code)     | PSRule           | Yes      | Parsed into `RemediationSnippets[]`                                                  |
| `RawRecordRef` (raw JSON path)                 | All              | Yes      | Provenance-side, kept on entity                                                      |

## 4. Top-3 enrichment patches (this PR)

### 4.1 PSRule

Adds `Impact` (severity-derived), `Effort` (severity-derived), `EvidenceUris`
(deduped LearnMoreUrl + DeepLinkUrl), `MitreTactics`, `MitreTechniques`,
`ScoreDelta` (pass-through), and `EntityRefs` seeded with the canonical
subscription. Wrapper-supplied values always win over derived defaults.

### 4.2 Kubescape

Adds `Impact` (severity-derived), `Effort` (severity-derived), `DeepLinkUrl`
(`hub.armosec.io/docs/<control>` fallback), `RemediationSnippets` (single
`text` snippet derived from prose `Remediation` when no structured snippet is
provided), `ScoreDelta` (pass-through), and `EntityRefs` seeded with the
subscription. Existing MITRE / framework / control plumbing is unchanged.

### 4.3 Scorecard

Adds `Impact` (severity-derived), `Effort` (severity-derived), `ScoreDelta`
(`10 - score` when the OpenSSF score is non-negative, otherwise `null`),
`MitreTactics`, `MitreTechniques`, and `EntityRefs` seeded with the parent
GitHub organisation derived from the canonical repo id (`host/owner`).
Existing score-based severity bucketing is preserved.

## 5. Deferred patches (#432c)

| Wrapper             | Missing dims dropped | Suggested patch                                                              |
| ------------------- | -------------------: | ---------------------------------------------------------------------------- |
| KubeBench           |                    5 | Add `Effort`, `EvidenceUris`, `MitreTactics/Techniques`, `ScoreDelta`        |
| SentinelCoverage    |                    6 | Add `Impact`, `Effort`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`|
| SentinelIncidents   |                    5 | Add `Impact`, `Effort`, `RemediationSnippets`, `BaselineTags`, `ScoreDelta`  |
| Prowler             |                    4 | Add `Impact`, `Effort`, `ScoreDelta`, `EntityRefs`                           |
| WARA                |                    4 | Add `EvidenceUris`, `MitreTactics/Techniques`, `ScoreDelta`                  |
| AzureQuotaReports   |                    4 | Add `RemediationSnippets`, `BaselineTags`, `MitreTactics/Techniques`         |
| IdentityGraphExp.   |                    4 | Add `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`      |
| Maester             |                    3 | Add `Impact`, `Effort`, `ScoreDelta` (from `severityScore`)                  |
| DefenderForCloud    |                    3 | Add `RemediationSnippets`, `BaselineTags`, `EntityRefs`                      |

The remaining 18 wrappers are within 1-3 dimensions of full coverage and form
the **#432c** wave (one-line additive changes, batch as a single PR).

## 6. Test contract

Regression tests live in `tests/normalizers/Track-D-Fidelity.Tests.ps1` and
re-use the existing `tests/fixtures/{psrule,kubescape,scorecard}-output.json`
fixtures so no new sanitisation surface is introduced. Each enriched dimension
is asserted on at least one finding, and the test guarantees the previous
zero-value defaults are no longer emitted for the patched fields.

## 7. Sanitisation

All audit doc lines, fixture references, and inbox notes are plain ASCII and
have been hand-checked. Fixtures referenced are pre-existing and were
sanitised at PR #465. No new tokens, PATs, connection strings, or tenant GUIDs
are introduced by this audit.
