---
name: "plan-vs-built-triage"
description: "When a multi-track plan references unbuilt modules, decide extract vs consume-as-built"
domain: "architecture"
confidence: "low"
source: "manual (first observation, issue #1056 triage 2026-05-13)"
---

## Context

Multi-track implementation plans name dependency modules by expected file path. Tracks often deliver the functionality under different file names, inside existing shared modules, or embedded in renderers. The D1 dependency gate catches the mismatch but cannot decide between extracting new helpers and consuming what landed.

## When to use this skill

An implementation plan references N modules by file path. The dependency gate reports M of them missing. Before filing extraction work, run through the checklist below.

## Checklist (all must fail to justify extraction)

1. **Function-name search.** Grep the codebase for the function name (not file name) the plan expects. If the function exists in a different file, update the plan's import path. No extraction needed.

2. **Cross-consumer duplication.** Count lines of logic duplicated across renderers that would collapse into the proposed helper. If total duplicated lines are under ~20, the extraction adds dependency surface without meaningful DRY benefit. Consume directly.

3. **Test isolation gain.** Check whether the renderers already have isolated test files. If yes, extracting a helper does not improve test granularity. If renderers share a single monolithic test and extraction would split it meaningfully, that is a point for extraction.

4. **Consumer-first layout (CON).** Does creating a new `modules/shared/FooHelper.ps1` serve any consumer besides Track F? If the helper has exactly one consumer, it is indirection, not reuse.

5. **Downstream coupling count.** In the plan, count how many slices import the missing module. If only 1 slice, consume directly. If 3+, extraction may pay off.

## Decision matrix

| Function found elsewhere | Duplication > 20 lines | Test isolation gain | Multiple consumers | Verdict |
|---|---|---|---|---|
| Yes | - | - | - | Option B (update import path) |
| No | Yes | Yes | Yes | Option A (extract) |
| No | No | No | No | Option B (consume as-built) |
| No | Mixed | Mixed | Mixed | Convene design review |

## Anti-patterns

- Assuming file-path stability across tracks. File layout decisions happen during implementation, not during planning. Plans that hard-code file paths will drift.
- Extracting a helper that has exactly one consumer. That is a wrapper around a wrapper.
- Blocking implementation on extraction when the as-built API is stable. The extraction can happen later if a second consumer appears.

## Examples

**Issue #1056:** Plan expected `EdgeRelations.ps1`, `Select-ReportArchitecture.ps1`, `PolicyCoverageAnalyzer.ps1`. Reality: EdgeRelations enum in Schema.ps1 (line 38), `Select-ReportArchitecture` in ReportManifest.ps1 (line 101), policy logic in `Policy/AlzMatcher.ps1` + `PolicyEnforcementRenderer.ps1`. Verdict: Option B, update plan import paths.

## Provenance

First observed during #1056 triage (Lead, 2026-05-13). Single observation. Promote confidence to "medium" if the pattern recurs in a second multi-track plan.
