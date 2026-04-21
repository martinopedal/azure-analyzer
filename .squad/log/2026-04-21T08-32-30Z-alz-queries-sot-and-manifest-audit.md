# Session Log — ALZ Queries SoT + Manifest Upstream Audit

**Date:** 2026-04-21
**Agents:** Atlas (background, claude-opus-4.7), Sage (background, claude-opus-4.7)

## What happened

Two parallel background agents ran:

1. **Atlas** audited the `alz-queries` upstream pointer in `tools/tool-manifest.json`, confirmed it points at the wrong repo (`Azure/Azure-Landing-Zones-Library` instead of `martinopedal/alz-graph-queries`), recommended Path A migration, and filed 6 issues (#314–#319) covering manifest fix, sync script, CI drift detection, folder reorganization, orphan query cleanup, and docs update.

2. **Sage** swept all 33 tools in the manifest for similar wrong-upstream bugs. Result: 1 🔴 (alz-queries — already tracked), 2 🟡 (alz-queries install block folded into #315; falco docs gap — low priority), 30 🟢. No new ALZ-class wrong-upstream bugs found.

## Artifacts produced

- `.squad/decisions/inbox/atlas-alz-queries-source-of-truth.md` (~22 KB brief + Filed Issues section)
- `.squad/decisions/inbox/sage-tool-upstream-audit.md` (audit report)
- GitHub issues #314–#319

## Decisions merged

Both inbox files merged into `.squad/decisions.md` under `## 2026-04-22 — ALZ Queries SoT Migration + Manifest Upstream Audit`.
