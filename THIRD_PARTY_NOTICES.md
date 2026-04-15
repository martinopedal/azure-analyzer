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
