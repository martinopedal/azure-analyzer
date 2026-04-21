# Orchestration Log: sage-falco-issue-filing

**Date:** 2026-04-21T08:40:39Z  
**Agent:** Sage (background, claude-opus-4.7)  
**Task:** Tool manifest upstream-pointer audit follow-up → falco install-mode docs gap

## Summary

Completed tool manifest upstream-pointer audit (30/33 tools). One documentation gap found in the falco tool.

## Findings

- **Issue:** Falco install-mode documentation gap — manifest install block does not declare dependencies on `helm` + `kubectl`.
- **Context:** Tool manifest upstream-pointer audit verified all 33 tools. Only `alz-queries` had a wrong upstream pointer (already in flight to fix). Falco install block is technically correct but incompletely documented.
- **Impact:** Low risk for users (both tools are commonly pre-installed in cluster contexts), but gaps in machine-readable dependency declaration can cause silent failures in air-gapped or minimal environments.

## Issue Filed

- #320: `chore: clarify falco manifest install block — query-mode vs install-mode prerequisites`
  - Labels: `squad`, `documentation`
  - Type: Documentation / Completeness

## Deliverables

- Research brief: `.squad/decisions/inbox/sage-tool-upstream-audit.md` (Section: ## Filed Issues)
- 1 documentation issue with clear remediation path
