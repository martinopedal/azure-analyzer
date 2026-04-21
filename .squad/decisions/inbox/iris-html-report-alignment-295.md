# Iris decision brief - HTML report alignment (#295)

## Decision

Implement the report page as a single-scroll layout matching `samples/sample-report.html`, while keeping data rendering server-side for findings rows and using client-side JS only for sort/filter/expand/theme interactions.

## Key implementation choices

1. **Heatmap fallback contract**: default matrix is Domain x Subscription when subscriptions exist; if no subscription dimension is present, fallback mode becomes Tool x Severity. Framework x Subscription remains available as a third mode when framework/sub data exists.
2. **Schema 2.2 fields** are rendered defensively (`if present -> render`, `if absent -> omit`) for: `Pillar`, `Frameworks`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `MitreTactics`, `MitreTechniques`.
3. **Sanitization boundary**: all dynamic strings pass through `Remove-Credentials` and HTML escaping before writing report output.

## Why

This preserves backward compatibility for pre-#299 payloads, aligns UI with the locked mockup, and avoids leaking unsanitized secrets in generated HTML.
