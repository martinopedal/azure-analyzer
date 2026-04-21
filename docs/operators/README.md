# Operators: Deploy and Maintain azure-analyzer

Guides for deploying, scheduling, and monitoring azure-analyzer in production.

## Deployment and Infrastructure

- **[Shared Infrastructure Modules](shared-infrastructure.md)** — Installer.ps1, RemoteClone.ps1, Retry.ps1, Sanitize.ps1, and other reusable helpers.
- **[Security Invariants](security-invariants.md)** — HTTPS-only, host allow-lists, credential scrubbing, timeout enforcement, and other non-negotiable safety rules.
- **[Continuous Control Patterns](continuous-control.md)** — OIDC federation, managed identities, scheduled runs, and monitoring/alerting.

## Key Principles

- **Read-only everywhere** — No write permissions on any cloud platform.
- **Cloud-first** — Fetch remote repos via HTTPS without manual cloning.
- **Credential hygiene** — Automatic token scrubbing from logs and output files.
- **Timeouts and retries** — Every external call wrapped with 300s timeout and jittered backoff.

---

**For extending azure-analyzer with new tools, see [../contributing/adding-a-tool.md](../contributing/adding-a-tool.md).**
