# cygnus-identitycorrelator-schema22

- Issue: #403
- Scope: Schema 2.2 ETL upgrade for identity-correlator
- Decision: Implemented wrapper and normalizer enrichment so identity attack-path findings now populate Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, MitreTactics, MitreTechniques, EntityRefs, and ToolVersion.
- MITRE policy: mapped tactics to TA0001, TA0006, and TA0008; mapped techniques to T1078, T1550, and T1021.
- Entity policy: `EntityRefs` includes canonical finding entity plus linked `appId:` and `objectId:` refs when available.
- Validation: fixture-backed normalizer tests added under `tests/fixtures/identity-graph/identity-correlation-output.json` and wrapper assertions added in `tests/shared/IdentityCorrelator.Tests.ps1`.
