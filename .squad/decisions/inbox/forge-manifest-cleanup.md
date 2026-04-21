# Forge Decision Inbox — Manifest cleanup (#314 #320 #321)

Date: 2026-04-22

## Decision

For the new `azure-quota` manifest registration, keep the existing CLI installer-compatible `install.command` field and also include `install.commands` from the locked mapping so current installer/tests stay green while preserving the planned schema signal.

## Rationale

- Current installer logic and Pester assertions (`tests/shared/Installer.Tests.ps1`) require `install.command` for `kind: "cli"`.
- Issue #321 mapping requires `commands: ["az"]`.
- Carrying both keys avoids breaking baseline behavior now and avoids a follow-up rebase churn when wrapper/normalizer work lands in #322-#325.

## Follow-up

- Consolidate on a single CLI install schema (`command` vs `commands`) in a dedicated compatibility PR once installer + tests are updated together.
