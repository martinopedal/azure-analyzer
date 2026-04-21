# Contributing to azure-analyzer

Extend, maintain, and improve azure-analyzer.

## For New Contributors

1. **[Contributing Guide](CONTRIBUTING.md)** — Code of conduct, pull request process, and issue triage.
2. **[Development Setup](development.md)** — Local environment, build commands, running tests.
3. **[Testing](testing.md)** — Pester test patterns, writing normalizer fixtures, mocking strategies.

## For Tool Maintainers and Extenders

- **[Adding a New Tool](adding-a-tool.md)** — End-to-end checklist: wrapper, normalizer, tests, docs, manifest registration.
- **[Troubleshooting](troubleshooting.md)** — Common failures, credential leak diagnosis, Pester drops.
- **[AI Governance](ai-governance.md)** — AI model selection, review gates, transparency in automation.

## Key Principles

- **Test-first**: Every new feature ships with passing Pester tests.
- **Manifest-driven**: New tools register in `tools/tool-manifest.json` before implementation.
- **Schema 2.2 contract**: All findings normalize to the unified schema.
- **Documentation is code**: Docs are versioned, tested, and kept current.

---

**For architecture deep dives, see [../architecture/](../architecture/).**
