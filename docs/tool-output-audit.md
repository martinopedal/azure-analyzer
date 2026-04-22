# Tool output fidelity audit (#432a)

> Track D / sub-task **#432a** of epic #427. Audit-first, doc-only, no schema changes. Input for **#432b** (FindingRow extension) and **#432c** (per-family adoption), both deferred post-window per Round 3 reconciliation.

## Methodology — audit-first, delta-only

This audit is **static** and **delta-only**. For every tool registered in `tools/tool-manifest.json` (the single source of truth) we:

1. Locate the wrapper (`modules/Invoke-<Tool>.ps1`) and normalizer (`modules/normalizers/Normalize-<Tool>.ps1`).
2. Statically extract the property names emitted on raw / v1-envelope finding objects in the wrapper.
3. Statically extract the `New-FindingRow` parameters bound (directly or via splat hashtable) in the normalizer.
4. Cross-reference the v2.2 `FindingRow` schema in `modules/shared/Schema.ps1`.
5. Diff (1) → (3) and classify each wrapper-emitted field as `preserved`, `suspected-dropped`, `confirmed-dropped`, or `n/a` (envelope/diagnostic).

Static analysis catches the majority of dropped fields, but per-tenant runtime payloads can include additional optional properties not visible to the script. Where confirmation requires actual tool execution against a live tenant we mark **`pending-real-tenant-run`** instead of **`complete`**. This is honest scope-flagging — #432b will only schema-add fields in the **`confirmed-dropped`** column built from the union of static analysis + the runtime-fixture pass that ships under #432c.

Sidecar machine-readable data: [`tool-output-audit.json`](./tool-output-audit.json).

## Tool inventory

Total tools registered: **37**  (enabled: **36**, disabled: **1**).

| Tool | Provider | Scope | Wrapper file | Wrapper-preserved fields | Normalizer-preserved fields | Tool-emitted fields not preserved (suspected) | Audit status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `azqr` | azure | subscription | `modules/Invoke-Azqr.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+22 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+23 more) | `Recommendation`, `RecommendationId` | complete (static); pending-real-tenant-run for runtime confirmation |
| `kubescape` | azure | subscription | `modules/Invoke-Kubescape.ps1` | _(none detected)_ | `BaselineTags`, `Category`, `Compliant`, `Controls`, `Detail`, `EntityId` (+19 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `kube-bench` | azure | subscription | `modules/Invoke-KubeBench.ps1` | _(none detected)_ | `BaselineTags`, `Category`, `Compliant`, `Controls`, `DeepLinkUrl`, `Detail` (+20 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `defender-for-cloud` | azure | subscription | `modules/Invoke-DefenderForCloud.ps1` | _(none detected)_ | `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort`, `EntityId` (+21 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `prowler` | azure | subscription | `modules/Invoke-Prowler.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Findings` (+18 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `EntityId` (+20 more) | `ResourceArn` | complete (static); pending-real-tenant-run for runtime confirmation |
| `falco` | azure | subscription | `modules/Invoke-Falco.ps1` | _(none detected)_ | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+24 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `azure-cost` | azure | subscription | `modules/Invoke-AzureCost.ps1` | _(none detected)_ | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+22 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `azure-quota` | azure | subscription | `modules/Invoke-AzureQuotaReports.ps1` | `Category`, `Compliant`, `CurrentValue`, `Detail`, `EntityType`, `ExitCode` (+25 more) | `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort`, `EntityId` (+16 more) | `CurrentValue`, `Kind`, `Limit`, `Location`, `MetricName`, `Package` (+8 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `finops` | azure | subscription | `modules/Invoke-FinOpsSignals.ps1` | `Category`, `Compliant`, `CostMap`, `Currency`, `Detail`, `DetectionCategory` (+16 more) | `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort`, `EntityId` (+20 more) | `CostMap`, `Currency`, `DetectionCategory`, `EstimatedMonthlyCost`, `Location`, `QueryId` (+3 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `appinsights` | azure | subscription | `modules/Invoke-AppInsights.ps1` | _(none detected)_ | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+19 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `loadtesting` | azure | subscription | `modules/Invoke-AzureLoadTesting.ps1` | _(none detected)_ | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+19 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `aks-rightsizing` | azure | subscription | `modules/Invoke-AksRightsizing.ps1` | `ExitCode` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+20 more) | _(none detected)_ | complete (static); pending-real-tenant-run for runtime confirmation |
| `aks-karpenter-cost` | azure | subscription | `modules/Invoke-AksKarpenterCost.ps1` | `ExitCode` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+21 more) | _(none detected)_ | complete (static); pending-real-tenant-run for runtime confirmation |
| `psrule` | azure | subscription | `modules/Invoke-PSRule.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Findings` (+13 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `EntityId` (+17 more) | _(none detected)_ | complete (static); pending-real-tenant-run for runtime confirmation |
| `powerpipe` | azure | subscription | `modules/Invoke-Powerpipe.ps1` | `Findings`, `Message`, `SchemaVersion`, `Source`, `Status`, `Subscription` (+1 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+23 more) | `Subscription` | complete (static); pending-real-tenant-run for runtime confirmation |
| `azgovviz` | azure | managementGroup | `modules/Invoke-AzGovViz.ps1` | `ExitCode`, `Findings`, `Message`, `Source`, `Status` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+23 more) | _(none detected)_ | complete (static); pending-real-tenant-run for runtime confirmation |
| `alz-queries` | azure | managementGroup | `modules/Invoke-AlzQueries.ps1` | `Category`, `Compliant`, `Description`, `Detail`, `Findings`, `Id` (+12 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+21 more) | `Description`, `QueryIntent`, `QuerySource`, `Subcategory` | complete (static); pending-real-tenant-run for runtime confirmation |
| `wara` | azure | subscription | `modules/Invoke-WARA.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+17 more) | `BaselineTags`, `Category`, `Compliant`, `Controls`, `DeepLinkUrl`, `Detail` (+20 more) | `PotentialBenefit`, `RecommendationId`, `RemediationSteps`, `ServiceCategory` | complete (static); pending-real-tenant-run for runtime confirmation |
| `maester` | microsoft365 | tenant | `modules/Invoke-Maester.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `EntityRefs` (+20 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `EntityId` (+19 more) | `TestId` | complete (static); pending-real-tenant-run for runtime confirmation |
| `scorecard` | github | repository | `modules/Invoke-Scorecard.ps1` | `BaselineTags`, `Category`, `CheckDetails`, `CheckName`, `Compliant`, `DeepLinkUrl` (+17 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `EntityId` (+15 more) | `CheckDetails`, `CheckName`, `Score` | complete (static); pending-real-tenant-run for runtime confirmation |
| `gh-actions-billing` | github | repository | `modules/Invoke-GhActionsBilling.ps1` | `after`, `Average`, `BaselineTags`, `before`, `Category`, `Compliant` (+28 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+19 more) | `after`, `before`, `Durations`, `language`, `Org`, `Repo` (+1 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `ado-connections` | ado | ado | `modules/Invoke-ADOServiceConnections.ps1` | `AdoOrg`, `AdoProject`, `AuthMechanism`, `AuthScheme`, `BaselineTags`, `Body` (+25 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+18 more) | `AdoOrg`, `AdoProject`, `AuthMechanism`, `AuthScheme`, `ConnectionId`, `ConnectionType` (+1 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `ado-pipelines` | ado | ado | `modules/Invoke-ADOPipelineSecurity.ps1` | `AdoOrg`, `AdoProject`, `AssetId`, `AssetName`, `AssetType`, `BaselineTags` (+28 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+21 more) | `AdoOrg`, `AdoProject`, `AssetId`, `AssetName`, `AssetType`, `Checks` (+2 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `ado-consumption` | ado | ado | `modules/Invoke-AdoConsumption.ps1` | `BaselineTags`, `Body`, `Category`, `Compliant`, `ContinuationToken`, `DeepLinkUrl` (+30 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+18 more) | `DefinitionIds`, `FailedRuns`, `FailRate`, `FirstAvg`, `PipelineEvidenceUris`, `Project` (+3 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `ado-repos-secrets` | ado | ado | `modules/Invoke-ADORepoSecrets.ps1` | `AdoOrg`, `AdoProject`, `ApiVersion`, `BaseUrl`, `BlobUrl`, `Body` (+33 more) | `BaselineTags`, `Category`, `Compliant`, `Confidence`, `DeepLinkUrl`, `Detail` (+19 more) | `AdoOrg`, `AdoProject`, `ApiVersion`, `BaseUrl`, `BlobUrl`, `CommitSha` (+11 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `ado-pipeline-correlator` | ado | ado | `modules/Invoke-ADOPipelineCorrelator.ps1` | `AdoOrg`, `AdoProject`, `BuildId`, `BuildTimestamp`, `BuildUrl`, `Category` (+21 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+17 more) | `AdoOrg`, `AdoProject`, `BuildId`, `BuildTimestamp`, `BuildUrl`, `CommitSha` (+6 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `identity-correlator` | graph | tenant | `modules/shared/IdentityCorrelator.ps1` | _(none detected)_ | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+19 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `identity-graph-expansion` | graph | tenant | `modules/Invoke-IdentityGraphExpansion.ps1` | `AppDisplayName`, `AppId`, `AppOwnerships`, `ClientId`, `Collector`, `ConsentGrants` (+26 more) | _(none detected)_ | `AppDisplayName`, `AppId`, `AppOwnerships`, `ClientId`, `Collector`, `ConsentGrants` (+20 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `zizmor` | cli | repository | `modules/Invoke-Zizmor.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+23 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+20 more) | `EndLine`, `RunMode`, `SinceUtc`, `StartLine` | complete (static); pending-real-tenant-run for runtime confirmation |
| `gitleaks` | cli | repository | `modules/Invoke-Gitleaks.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `DisablesDefaultsWithoutCustomRules` (+28 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+19 more) | `DisablesDefaultsWithoutCustomRules`, `Host`, `Owner`, `RepositoryEntityId`, `RepositoryId`, `RepositoryUrl` | complete (static); pending-real-tenant-run for runtime confirmation |
| `trivy` | cli | repository | `modules/Invoke-Trivy.ps1` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+22 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+20 more) | `ParsedVersion`, `RawOutput` | complete (static); pending-real-tenant-run for runtime confirmation |
| `bicep-iac` | cli | repository | `modules/Invoke-IaCBicep.ps1` | `Findings`, `Message`, `SchemaVersion`, `Source`, `Status` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+20 more) | _(none detected)_ | complete (static); pending-real-tenant-run for runtime confirmation |
| `infracost` | cli | repository | `modules/Invoke-Infracost.ps1` | `BaselineMonthlyCost`, `Category`, `Compliant`, `Currency`, `DeepLinkUrl`, `Detail` (+30 more) | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+21 more) | `BaselineMonthlyCost`, `Currency`, `DiffMonthlyCost`, `MonthlyCost`, `ProjectName`, `ProjectPath` (+6 more) | complete (static); pending-real-tenant-run for runtime confirmation |
| `terraform-iac` | cli | repository | `modules/Invoke-IaCTerraform.ps1` | `Findings`, `Message`, `SchemaVersion`, `Source`, `Status` | `BaselineTags`, `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `Effort` (+21 more) | _(none detected)_ | complete (static); pending-real-tenant-run for runtime confirmation |
| `sentinel-incidents` | azure | workspace | `modules/Invoke-SentinelIncidents.ps1` | _(none detected)_ | `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `EntityId`, `EntityRefs` (+18 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `sentinel-coverage` | azure | workspace | `modules/Invoke-SentinelCoverage.ps1` | _(none detected)_ | `Category`, `Compliant`, `DeepLinkUrl`, `Detail`, `EntityId`, `EntityRefs` (+18 more) | _(none detected)_ | pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty) |
| `copilot-triage` | cli | repository | `modules/Invoke-CopilotTriage.ps1` | _(none detected)_ | _(none detected)_ | _(none detected)_ | disabled (skipped) |

## Candidate FindingRow additions for #432b

Fields below are emitted by one or more tool wrappers but have **no home in the current `FindingRow`** and are not preserved by their normalizer. Ordered by occurrence count across the enabled tool set. **#432b** will use this list to propose additive schema fields after foundation #435 lands; **#432c** will then drive per-family normalizer adoption.

| # | Candidate field | Occurrence (tools) | Notes |
| --- | --- | ---:| --- |
| 1 | `AdoOrg` | 4 | ADO organisation context — currently leaks into Detail blob. |
| 2 | `AdoProject` | 4 | ADO project context — currently leaks into Detail blob. |
| 3 | `CommitSha` | 2 | Git commit SHA for SCM-scoped findings (gitleaks, scorecard, zizmor, trivy). |
| 4 | `CommitUrl` | 2 | Browser-deep-link to the offending commit; useful for HTML report drilldowns. |
| 5 | `Currency` | 2 | ISO 4217 currency for cost-bearing findings (azure-cost, infracost, finops). |
| 6 | `DisablesDefaultsWithoutCustomRules` | 2 | PSRule meta-flag indicating baseline-suppressed rule set. |
| 7 | `Location` | 2 | Azure region for the finding subject; useful for residency / quota dashboards. |
| 8 | `Recommendation` | 2 | Free-form recommendation string from advisor-style tools. |
| 9 | `RecommendationId` | 2 | Stable advisor / WARA / reliability recommendation id; overlaps with `RuleId` but emitted distinctly. |
| 10 | `Repo` | 2 | Short owner/repo identifier (distinct from `EntityId` canonical form). |
| 11 | `RepositoryCanonicalId` | 2 | Canonical repo entity id when wrapper produces multiple kinds. |
| 12 | `RepositoryId` | 2 | GitHub numeric repo id; useful for cross-correlation. |
| 13 | `ResourceName` | 2 | Display name distinct from canonical id; HTML report uses it today via Detail parsing. |
| 14 | `ResourceType` | 2 | ARM resource type already present in `ResourceId`, but explicit field eases grouping. |
| 15 | `SecretType` | 2 | Detector classification for secret-scanner findings (gitleaks, ado-repos-secrets). |
| 16 | `after` | 1 |  |
| 17 | `ApiVersion` | 1 |  |
| 18 | `AppDisplayName` | 1 |  |
| 19 | `AppId` | 1 |  |
| 20 | `AppOwnerships` | 1 |  |
| 21 | `AssetId` | 1 |  |
| 22 | `AssetName` | 1 |  |
| 23 | `AssetType` | 1 |  |
| 24 | `AuthMechanism` | 1 |  |
| 25 | `AuthScheme` | 1 |  |
| 26 | `BaselineMonthlyCost` | 1 |  |
| 27 | `BaseUrl` | 1 |  |
| 28 | `before` | 1 |  |
| 29 | `BlobUrl` | 1 |  |
| 30 | `BuildId` | 1 |  |
| 31 | `BuildTimestamp` | 1 |  |
| 32 | `BuildUrl` | 1 |  |
| 33 | `CheckDetails` | 1 |  |
| 34 | `CheckName` | 1 |  |
| 35 | `Checks` | 1 |  |
| 36 | `ClientId` | 1 |  |
| 37 | `Collector` | 1 |  |
| 38 | `ConnectionId` | 1 |  |
| 39 | `ConnectionType` | 1 |  |
| 40 | `ConsentGrants` | 1 |  |
| 41 | `ConsentType` | 1 |  |
| 42 | `CorrelationStatus` | 1 |  |
| 43 | `CostMap` | 1 |  |
| 44 | `CurrentValue` | 1 |  |
| 45 | `DefinitionIds` | 1 |  |
| 46 | `Deployment` | 1 |  |
| 47 | `Description` | 1 |  |
| 48 | `DetectionCategory` | 1 |  |
| 49 | `DiffMonthlyCost` | 1 |  |
| 50 | `Durations` | 1 |  |
| 51 | `EdgeCount` | 1 |  |
| 52 | `Edges` | 1 |  |
| 53 | `EndLine` | 1 |  |
| 54 | `Error` | 1 |  |
| 55 | `EstimatedMonthlyCost` | 1 |  |
| 56 | `ExpansionSummary` | 1 |  |
| 57 | `FailedRuns` | 1 |  |
| 58 | `FailRate` | 1 |  |
| 59 | `FilePath` | 1 |  |
| 60 | `FirstAvg` | 1 |  |
| 61 | `GroupId` | 1 |  |
| 62 | `GroupMemberships` | 1 |  |
| 63 | `GroupName` | 1 |  |
| 64 | `Guests` | 1 |  |
| 65 | `Host` | 1 |  |
| 66 | `IsShared` | 1 |  |
| 67 | `Kind` | 1 |  |
| 68 | `language` | 1 |  |
| 69 | `Limit` | 1 |  |
| 70 | `LineNumber` | 1 | Source line for SCA / SAST / IaC findings — drives editor deep-links. |
| 71 | `MetricName` | 1 |  |
| 72 | `MonthlyCost` | 1 |  |
| 73 | `Oid` | 1 |  |
| 74 | `Org` | 1 |  |
| 75 | `Organization` | 1 |  |
| 76 | `Owner` | 1 |  |
| 77 | `OwnerId` | 1 |  |
| 78 | `OwnerType` | 1 |  |
| 79 | `Package` | 1 |  |
| 80 | `ParsedVersion` | 1 |  |
| 81 | `PipelineEvidenceUris` | 1 |  |
| 82 | `PipelineResourceId` | 1 |  |
| 83 | `PotentialBenefit` | 1 |  |
| 84 | `PrincipalCapHit` | 1 |  |
| 85 | `PrincipalCount` | 1 |  |
| 86 | `PrincipalId` | 1 |  |
| 87 | `PrincipalType` | 1 |  |
| 88 | `Project` | 1 |  |
| 89 | `ProjectName` | 1 |  |
| 90 | `ProjectPath` | 1 |  |
| 91 | `ProjectTotalMonthlyCost` | 1 |  |
| 92 | `QueryId` | 1 |  |
| 93 | `QueryIntent` | 1 | Copilot-triage classified user intent label (when triage is enabled). |
| 94 | `QuerySource` | 1 |  |
| 95 | `RawOutput` | 1 |  |
| 96 | `RbacAssignments` | 1 |  |
| 97 | `Reason` | 1 |  |
| 98 | `RemediationSteps` | 1 |  |
| 99 | `RepositoryEntityId` | 1 |  |
| 100 | `RepositoryName` | 1 |  |
| 101 | `RepositoryUrl` | 1 |  |
| 102 | `ResourceArn` | 1 |  |
| 103 | `RoleDefinitionName` | 1 |  |
| 104 | `RunMode` | 1 |  |
| 105 | `Runs` | 1 |  |
| 106 | `Score` | 1 |  |
| 107 | `SecondAvg` | 1 |  |
| 108 | `SecretFindingId` | 1 |  |
| 109 | `Service` | 1 |  |
| 110 | `ServiceCategory` | 1 |  |
| 111 | `SinceUtc` | 1 |  |
| 112 | `Skipped` | 1 |  |
| 113 | `SkipReason` | 1 |  |
| 114 | `Sku` | 1 |  |
| 115 | `StartLine` | 1 |  |
| 116 | `Subcategory` | 1 |  |
| 117 | `Subscription` | 1 |  |
| 118 | `Success` | 1 |  |
| 119 | `TestId` | 1 |  |
| 120 | `Threshold` | 1 |  |
| 121 | `ThrottledCollectors` | 1 |  |
| 122 | `TimestampUtc` | 1 |  |
| 123 | `ToolSummary` | 1 |  |
| 124 | `TotalHourlyCost` | 1 |  |
| 125 | `TotalMinutes` | 1 |  |
| 126 | `TotalMonthlyCost` | 1 |  |
| 127 | `TotalRuns` | 1 |  |
| 128 | `Unit` | 1 |  |
| 129 | `Url` | 1 |  |
| 130 | `UsagePercent` | 1 |  |

## Existing FindingRow optional fields with low normalizer adoption

Schema v2.2 already defines these fields, but most normalizers do not yet populate them. They are **not** new schema work — they are **adoption gaps** for #432c. Listed by miss-count across the 36 enabled tools.

| Schema field | Normalizers not populating |
| --- | ---:|
| `Controls` | 33 |
| `MitreTactics` | 22 |
| `MitreTechniques` | 22 |
| `ScoreDelta` | 21 |
| `Frameworks` | 13 |
| `RuleId` | 11 |
| `Effort` | 9 |
| `RemediationSnippets` | 9 |
| `Impact` | 8 |
| `BaselineTags` | 6 |
| `EntityRefs` | 6 |
| `EvidenceUris` | 5 |
| `DeepLinkUrl` | 2 |
| `Pillar` | 1 |
| `ToolVersion` | 1 |

## Audit status legend

- **complete (static)** — wrapper + normalizer both inspected; field deltas computed from source.
- **pending-real-tenant-run** — confirmation requires running the tool against a live Azure / M365 / GitHub / ADO tenant. Most rows carry this flag because per-tenant payloads frequently expose optional properties not visible to static analysis.
- **disabled (skipped)** — tool is `enabled: false` in the manifest (e.g. `copilot-triage`).

## How to regenerate this audit

```powershell
# 1. Static field extraction → audit-raw.json
pwsh -NoProfile -File scripts/audit-tool-fields.ps1
# 2. Render markdown + sidecar JSON
pwsh -NoProfile -File scripts/render-tool-output-audit.ps1
```

Both scripts read `tools/tool-manifest.json` (the single source of truth — see `.github/copilot-instructions.md`). Adding or removing a tool there will propagate into the next audit regeneration without further edits.

