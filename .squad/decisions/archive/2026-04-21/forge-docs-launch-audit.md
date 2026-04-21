# forge docs launch readiness audit

Date: 2026-04-21
Scope: README.md, PERMISSIONS.md, CHANGELOG.md, SECURITY.md, CONTRIBUTING.md, docs/*.md

## Findings and actions
- README first-screen flow is clear. It states what the tool is, points to output examples, and includes install plus quickstart.
- Sample report links are already prominent near the top. Kept as-is.
- Regenerated tool catalogs with scripts/Generate-ToolCatalog.ps1. Catalog files updated and kept.
- Regenerated permissions index with scripts/Generate-PermissionsIndex.ps1. PERMISSIONS.md updated and kept.
- Schema 2.2 coverage is clearly called out in README with Pillar, Frameworks, and MITRE references.
- Ran markdown-link-check for README. All links passed.
- Removed remaining em dash characters from CHANGELOG.md to satisfy docs style rule.
- Verified badge URLs return HTTP 200 for CI, CodeQL, and License badges.
- Verified LICENSE file exists and matches README MIT claim.

## Validation
- Invoke-Pester -Path .\\tests -CI passed.
