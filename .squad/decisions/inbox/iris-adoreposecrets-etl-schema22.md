# Decision: ado-repos-secrets Schema 2.2 ETL

Issue: #370
Date: 2026-04-21

## Scope
Implemented Schema 2.2 ETL for ado-repos-secrets wrapper and normalizer, including security metadata, evidence URIs, deep links, baseline tags, and tool version propagation.

## Key decisions
1. Keep Platform as `ADO` in `New-FindingRow` to satisfy the locked schema validation enum.
2. Build ADO commit/blob/deeplink URLs from org, project, repo, commit, file, and line metadata.
3. Use title format `SecretType in file:line` to preserve finding distinctness under EntityStore finding dedup key.
4. Emit baseline tags as secret type, confidence tier (`high|medium|low`), and `ruleId:<id>`.
5. Attach a text remediation snippet with provider-specific rotation documentation links and history scrub guidance.

## Validation
- Focused tests: `Normalize-ADORepoSecrets.Tests.ps1` and `Invoke-ADORepoSecrets.Tests.ps1` passed.
- Full suite: `Invoke-Pester -Path .\tests -CI` passed (1413 passed, 0 failed, 5 skipped).
