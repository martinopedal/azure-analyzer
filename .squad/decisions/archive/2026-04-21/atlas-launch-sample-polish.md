# Launch-day sample report polish

Updated the sample report pipeline so launch artifacts showcase Schema 2.2 context end to end.

## What changed
- Curated a new sample findings dataset with representative tools: azqr, psrule, kubescape, sentinel-coverage, ado-pipeline-correlator, appinsights, finops-signals, ado-consumption, gh-actions-billing, and aks-rightsizing.
- Regenerated `samples/sample-report.html` and `samples/sample-report.md` from the curated dataset.
- Improved HTML report rendering to show pillar breakdown, tool-color badges from `tool-manifest.json`, and expanded details for BaselineTags, EntityRefs, ScoreDelta, remediation snippets, MITRE, evidence links, and deep links.
- Improved Markdown report rendering with a Schema 2.2 spotlight table plus expandable evidence and remediation snippets.

Before vs after: static sample docs with mostly legacy framing became launch-grade Schema 2.2 showcases with pillar, framework, MITRE, deep-link, snippet, and cross-entity context visible at first glance.
