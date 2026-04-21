# Iris drop-box: AzGovViz ETL Schema 2.2 (#307)

## 2026-04-21

- Implemented wrapper enrichment in `modules/Invoke-AzGovViz.ps1` for `Pillar`, `Frameworks`, `BaselineTags`, `DeepLinkUrl`, `EvidenceUris`, and `ToolVersion`.
- Added AzGovViz cost signal parsing for `*OrphanedResources*.csv` and mapped it to `Category=Cost` and `Pillar=Cost`.
- Added policy framework projection shape:
  - `@{ Name = 'ALZ'; Controls = @(<policySetId>) }`
  - `@{ Name = 'MCSB'; Controls = @(<mcsbControlIds...>) }`
- Normalizer now emits Schema 2.2 fields through `New-FindingRow` and resolves entity scope to `Subscription`, `ManagementGroup`, `Tenant`, or `AzureResource`.
- Added parent reference emission in `EntityRefs` for subscription, management-group, and tenant chain hints when available.
- Extended AzGovViz fixtures and tests to verify pillar derivation, framework and baseline extraction, and entity dedup behavior through `EntityStore`.
