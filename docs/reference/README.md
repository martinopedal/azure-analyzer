# Reference Documentation

Deep dives into schemas, catalogs, and field mappings.

## Quick Links

- [Tool Catalog](tool-catalog.md) — All tools registered in the manifest, showing enabled + opt-in entries (counts reflect the current manifest).
- [Orchestrator Parameters](orchestrator-params.md) — Every Invoke-AzureAnalyzer.ps1 parameter (common visible, advanced collapsed).
- [ETL Pipeline](etl-pipeline.md) — From raw tool output to unified schema (v1 to v3).
- [Schema 2.2 Specification](schema-2.2.md) — Complete FindingRow schema with 32 fields.
- [Entity Model](entity-model.md) — Entity types, canonical IDs, and the entity store.
- [Permission Scopes](permissions/README.md) — Per-tool permission requirements.

## For Consumers

- **[Tool Catalog](tool-catalog.md)** — What each tool does, what it scans, and how to invoke it.
- **[Orchestrator Parameters](orchestrator-params.md)** — All parameters grouped by common use case.
- **[ETL Pipeline](etl-pipeline.md)** — Understanding the flow: raw output → findings → entities.

## For Maintainers

- **[Tool Catalog (Contributor)](tool-catalog-contributor.md)** — Full manifest data per tool for extension.
- **[Schema 2.2 Specification](schema-2.2.md)** — Complete field definitions and normalizer contract.
- **[Permission Scopes (Full Index)](permissions/README.md)** — All permission requirements per tool and permission tier.
- **[Entity Model](entity-model.md)** — Entity types, dedup strategy, and cross-tool merging.
