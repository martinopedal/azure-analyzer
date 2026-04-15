# Work Routing

How to decide who handles what.

## Work Type → Agent

| Work Type | Route To | Examples |
|-----------|----------|----------|
| ARG KQL queries | Atlas | New checklist item queries, query fixes, EMPTY/ERROR investigation, `alz_additional_queries.json` changes |
| Entra ID / Microsoft Graph checks | Iris | Conditional Access, PIM, MFA, emergency accounts, Entra Connect, identity RBAC checks |
| Azure DevOps API checks | Forge | Branch policies, pipelines, service connections, variable groups |
| GitHub API checks | Forge | Branch protection, secret scanning, Dependabot, CODEOWNERS, Actions workflows |
| Recommendation aggregation / scoring | Sentinel | Unified output format, severity weighting, azqr integration, report generation |
| Repository security standards | Sentinel | Secret scanning status, Dependabot alerts, branch protection validation |
| Pre-build research / tool scouting | Sage | "Does this already exist?", tool bundling candidates, API capability research, breaking-change impact |
| Issue triage & task decomposition | Lead | All `squad`-labeled issues, design reviews, PR sign-off |
| Code review | Lead | Review PRs, check quality, enforce conventions |
| Scope & priorities | Lead | What to build next, trade-offs, cross-agent decisions |
| Session logging | Scribe | Automatic — never needs routing |

## Module Ownership

| Path | Owner | Notes |
|------|-------|-------|
| queries/ | Atlas | KQL queries and alz_additional_queries.json |
| modules/Invoke-AlzQueries.ps1 | Atlas | ALZ query runner |
| modules/Invoke-Azqr.ps1 | Sentinel | azqr integration |
| modules/Invoke-PSRule.ps1 | Sentinel | PSRule integration |
| modules/Invoke-AzGovViz.ps1 | Sentinel | AzGovViz integration |
| modules/Invoke-WARA.ps1 | Sentinel | WARA integration |
| src/ | Forge | Python orchestrator |
| .github/workflows/ | Forge | CI/CD workflows |
| PERMISSIONS.md | Iris | Graph API permissions doc |
| New-HtmlReport.ps1 | Sentinel | Report generation |
| New-MdReport.ps1 | Sentinel | Report generation |
| Invoke-AzureAnalyzer.ps1 | Lead | Main entry point |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Lead |
| `squad:{name}` | Pick up issue and complete the work | Named member |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, the **Lead** triages it — analyzing content, assigning the right `squad:{member}` label, and commenting with triage notes.
2. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
3. Members can reassign by removing their label and adding another member's label.
4. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.
