# ADO pipeline consumption - Required permissions

**Display name:** ADO Pipeline Consumption

**Scope:** ado | **Provider:** ado

The ADO consumption wrapper reads build run telemetry to detect cost and reliability regressions. It only performs GET operations against Azure DevOps REST APIs.
Findings are emitted with Schema 2.2 cost-governance metadata (`Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `ToolVersion`).

## Required PAT scopes

| PAT scope | Why |
|---|---|
| `Build (Read)` | Read build run history and result metadata |
| `Project and Team (Read)` | Enumerate projects when `-AdoProject` is not specified |
| `Identity (Read)` | Resolve project context and principal metadata returned by build APIs |

## Parameters

- `-AdoOrg <name>` (required): Azure DevOps organization (`-Organization` alias retained for backward compatibility).
- `-AdoProject <name>` (optional): single project filter (`-Project` alias retained for backward compatibility).
- `-DaysBack <int>` (default `30`): telemetry lookback.
- `-MonthlyBudgetUsd <double>` (optional): soft cost threshold.
- `-AdoPat <token>` (optional): PAT override; env fallback supported.

## What it scans

- Project share of org runner-minute consumption.
- Build duration regression greater than 25 percent.
- Failed build run rate greater than 10 percent.
- Optional budget overrun signal when `-MonthlyBudgetUsd` is supplied.

## What it does NOT do

- No pipeline edits.
- No variable or agent pool changes.
