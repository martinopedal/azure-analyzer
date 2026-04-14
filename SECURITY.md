# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, report it responsibly using [GitHub Security Advisories](https://github.com/martinopedal/azure-analyzer/security/advisories/new).

Do not open a public issue. Public disclosure before a fix is in place puts users at risk.

The maintainer will acknowledge the report within 5 business days and aim to release a fix within 30 days for confirmed vulnerabilities.

## Supported Versions

Only the latest version on the `main` branch is supported with security updates.

## Scope

This tool is a read-only Azure assessment runner. It does not write to Azure resources, store credentials, or transmit data externally. Findings are written locally.

Relevant vulnerability classes include:

- Credential or secret leakage in output files or logs
- Injection vulnerabilities in query or report generation
- Supply chain issues in bundled tool versions
- Workflow injection in GitHub Actions workflows
