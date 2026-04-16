# Third-Party Notices

This project invokes, wraps, or depends on the following open-source tools. None are bundled - each must be installed separately.

---

## Azure Quick Review (azqr)
- **Source:** https://github.com/Azure/azqr
- **Install:** https://azure.github.io/azqr
- **Copyright:** Copyright (c) Microsoft Corporation
- **License:** MIT License

---

## AzGovViz - Azure Governance Visualizer
- **Source:** https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting
- **Copyright:** Copyright (c) 2020 Julian Hayward
- **License:** MIT License
- **Install:** Clone the repo. `Invoke-AzGovViz.ps1` looks for `AzGovVizParallel.ps1` in standard paths.

---

## PSRule for Azure
- **Source:** https://github.com/Azure/PSRule.Rules.Azure
- **Copyright:** Copyright (c) Microsoft Corporation and contributors
- **License:** MIT License
- **Install:** `Install-Module PSRule.Rules.Azure`

---

## WARA - Well-Architected Reliability Assessment
- **Source:** https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2
- **Copyright:** Copyright (c) Microsoft Corporation
- **License:** MIT License
- **Install:** `Install-Module WARA`

---

## Az PowerShell Modules
- **Source:** https://github.com/Azure/azure-powershell
- **Copyright:** Copyright (c) Microsoft Corporation
- **License:** Apache License 2.0
- **Install:** `Install-Module Az`

---

## ALZ Graph Queries
- **Source:** https://github.com/martinopedal/alz-graph-queries
- **Copyright:** Copyright (c) Microsoft Corporation (original work), derived by martinopedal
- **License:** MIT License
- **Usage:** The ALZ Resource Graph queries (132 custom ARG queries) are bundled from this project and automatically loaded by `modules/Invoke-AlzQueries.ps1`.

---

## Azure Review Checklists (upstream source)
- **Source:** https://github.com/Azure/review-checklists
- **Copyright:** Copyright (c) Microsoft Corporation
- **License:** MIT License
- **Note:** The alz-graph-queries project (used by azure-analyzer) derives from this upstream project. This represents the original ALZ checklist data from which the ARG queries were generated.

---

## Maester
- **Source:** https://github.com/maester365/maester
- **Copyright:** Copyright (c) Maester365 contributors
- **License:** MIT License
- **Install:** `Install-Module Maester -Scope CurrentUser`
- **Usage:** Invoked via `Invoke-Maester` to assess Entra ID security configuration against EIDSCA and CISA baselines

---

## OpenSSF Scorecard
- **Source:** https://github.com/ossf/scorecard
- **Copyright:** Copyright (c) OpenSSF Contributors
- **License:** Apache License 2.0
- **Install:** Download from https://github.com/ossf/scorecard/releases
- **Usage:** Invoked via `scorecard` CLI to assess repository security practices (branch protection, dependency pinning, CI configuration)

---

## zizmor
- **Source:** https://github.com/woodruffw/zizmor
- **Copyright:** Copyright (c) William Woodruff and zizmor contributors
- **License:** Apache License 2.0
- **Install:** `pipx install zizmor` (or `pip install --user zizmor`)
- **Usage:** Invoked via the `zizmor` CLI to audit GitHub Actions workflows for expression-injection and supply-chain risks.

---

## gitleaks
- **Source:** https://github.com/gitleaks/gitleaks
- **Copyright:** Copyright (c) Zachary Rice and gitleaks contributors
- **License:** MIT License
- **Install:** `winget install gitleaks.gitleaks` / `brew install gitleaks` / release binaries.
- **Usage:** Invoked via the `gitleaks` CLI to scan the repository for committed secrets.

---

## Trivy
- **Source:** https://github.com/aquasecurity/trivy
- **Copyright:** Copyright (c) Aqua Security Software Ltd.
- **License:** Apache License 2.0
- **Install:** `winget install AquaSecurity.Trivy` / `brew install trivy` / release binaries.
- **Usage:** Invoked via the `trivy` CLI to scan repository filesystems for vulnerable dependencies, misconfigurations, and secrets.

---

# First-Party Components (azure-analyzer)

The following components are developed as part of this repository and are
licensed under the MIT License in [LICENSE](LICENSE):

- **ADO Service Connections scanner** - Native REST API collector (no external
  dependency). Source: `modules/Invoke-ADOServiceConnections.ps1` +
  `modules/normalizers/Normalize-ADOConnections.ps1`.
- **Identity Correlator** - Post-processor that links entities across Azure,
  Entra, and repositories. Source: `modules/shared/IdentityCorrelator.ps1`.
- **Manifest-driven prerequisite installer** - Source: `modules/shared/Installer.ps1`.
- **Unified HTML / Markdown reports** - Source: `New-HtmlReport.ps1`,
  `New-MdReport.ps1`, `report-template.html`.
- **Orchestrator, schema, normalizers, and entity store** - Source:
  `Invoke-AzureAnalyzer.ps1`, `modules/shared/Schema.ps1`,
  `modules/normalizers/*`, `modules/shared/EntityStore.ps1`.

Copyright (c) 2026 martinopedal. See [LICENSE](LICENSE) for the full text.
