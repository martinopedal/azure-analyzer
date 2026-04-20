# Contributor documentation

Contributor and developer reference. Squad coordination lives in `.squad/`.

- [ARCHITECTURE.md](ARCHITECTURE.md) - High-level architecture, modules, and data flow.
- [adding-a-tool.md](adding-a-tool.md) - End-to-end guide for registering and wiring a new analyzer tool.
- [tool-catalog.md](tool-catalog.md) - Full manifest projection (provider, normalizer, install kind, upstream pin, report color/phase). Generated from `tools/tool-manifest.json`.
- [operations.md](operations.md) - Operator runbook: shared infrastructure, security invariants, continuous-control mode, multi-tenant fan-out.
- [troubleshooting.md](troubleshooting.md) - Diagnose tool failures, throttling, leaked credentials, Pester drops, stale catalog.
- [ai-governance.md](ai-governance.md) - AI governance, model selection, and review-gate policy for the repo.
- [proposals/](proposals/) - Forward-looking design proposals (IaC drift, Copilot triage panel, and more).
