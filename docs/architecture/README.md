# Architecture: How azure-analyzer Works

Deep dives into design, data flow, and implementation details.

## Core Concepts

- **[Overview](overview.md)** — Modules, data flow, and orchestrator entry points.
- **[Normalizer Contract](normalizer-contract.md)** — v1 wrapper → v2 normalizer → v3 entity store (ETL pipeline).
- **[Entity Model and Deduplication](entity-model.md)** — Entity types, canonical IDs, and cross-tool merging.
- **[Permission Tiers](permission-tiers.md)** — 0-6 tier breakdown with security model.
- **[End-to-End Data Flow](data-flow.md)** — From scan invocation to report generation.

## Key Design Decisions

- **Unified schema**: v2 FindingRow with 32 fields, Schema 2.2.
- **Entity-centric storage**: Deduplicated entities with cross-tool references.
- **Progressive disclosure**: Documentation with expandable sections for advanced details.
- **Cloud-first targeting**: Remote repositories via HTTPS with automatic credential scrubbing.
- **Manifest-driven tools**: Single source of truth in `tools/tool-manifest.json`.

---

**For implementation and testing, see [../contributing/](../contributing/).**
