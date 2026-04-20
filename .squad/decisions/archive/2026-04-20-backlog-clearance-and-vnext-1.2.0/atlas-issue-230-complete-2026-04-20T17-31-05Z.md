# Atlas - Issue #230 complete: framework x tool coverage matrix

- **Date (UTC):** 2026-04-20T17:31:39Z
- **Agent:** Atlas
- **Issue:** [#230](https://github.com/martinopedal/azure-analyzer/issues/230) - "feat(reports): framework x tool coverage matrix"
- **Decision status:** Implemented in branch `feat/230-framework-matrix`.

## Framework taxonomy

Seed taxonomy in manifest and report matrix:

- CIS Azure
- NIST 800-53
- Azure WAF
- Azure CAF
- SOC2
- PCI-DSS

## Manifest schema delta

Added `frameworks: []` on every `tools[]` entry in `tools/tool-manifest.json`.

- Mapping source of truth is now the manifest (Option A from issue design).
- Disabled tools still carry `frameworks` for schema consistency.
- Empty array means unmapped / intentionally no framework declaration.

## Initial mapping table (for copy/paste on new tools)

| Tool | Frameworks |
|---|---|
| azqr | Azure WAF, Azure CAF |
| kubescape | CIS Azure, NIST 800-53 |
| kube-bench | CIS Azure |
| defender-for-cloud | CIS Azure, NIST 800-53, Azure WAF, Azure CAF, SOC2, PCI-DSS |
| falco | CIS Azure, NIST 800-53 |
| azure-cost | Azure CAF |
| finops | Azure WAF, Azure CAF |
| appinsights | Azure WAF |
| loadtesting | Azure WAF |
| aks-rightsizing | Azure WAF, Azure CAF |
| psrule | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| azgovviz | Azure WAF, Azure CAF |
| alz-queries | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| wara | Azure WAF, Azure CAF |
| maester | NIST 800-53, SOC2, PCI-DSS |
| scorecard | NIST 800-53, SOC2 |
| ado-connections | NIST 800-53, SOC2, PCI-DSS |
| ado-pipelines | NIST 800-53, SOC2, PCI-DSS |
| ado-repos-secrets | NIST 800-53, SOC2, PCI-DSS |
| ado-pipeline-correlator | NIST 800-53, SOC2 |
| identity-correlator | NIST 800-53, SOC2, PCI-DSS |
| identity-graph-expansion | NIST 800-53, SOC2 |
| zizmor | NIST 800-53, SOC2 |
| gitleaks | NIST 800-53, SOC2, PCI-DSS |
| trivy | CIS Azure, NIST 800-53, PCI-DSS |
| bicep-iac | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| infracost | Azure CAF |
| terraform-iac | CIS Azure, NIST 800-53, Azure WAF, Azure CAF |
| sentinel-incidents | NIST 800-53, SOC2 |
| sentinel-coverage | NIST 800-53, SOC2, PCI-DSS, Azure WAF |
| copilot-triage | *(none)* |

## Report integration summary

- Added **Framework Coverage** section in `New-HtmlReport.ps1` below the severity heatmap.
- Matrix rows = frameworks, columns = enabled tools from manifest.
- Cell behavior:
  - `-` for no tool/framework mapping.
  - `✓ 0` for mapped with zero findings.
  - Count + per-severity mini chips for mapped intersections with findings.
  - Weighted heat intensity by severity distribution.
- Added summary column (total per framework) and summary row (total per tool).
- Added click-to-filter integration via global filter state (`tool + framework`).

## Validation snapshot

- Added tests: `tests/reports/Framework-Matrix.Tests.ps1`.
- Full suite: **1294 passed, 0 failed, 5 skipped**.
- Catalog freshness regeneration completed:
  - `pwsh scripts/Generate-ToolCatalog.ps1`
  - `pwsh scripts/Generate-PermissionsIndex.ps1`

## Notes

Severity strip (#270 lineage) and collapsible findings tree (#275 lineage) remain intact and covered by existing tests.
