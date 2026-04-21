### 2026-04-21T17:00:00Z: User directive — Memory vault is the cross-repo memory layer

**By:** Martin Opedal (via Copilot)

**What:** All squad agents working in code repos (azure-analyzer included) write durable cross-repo learnings to `C:\git\memory-vault` (Obsidian vault, repo `martinopedal/memory-vault`) in addition to in-repo `.squad/` files. Connect content is excluded by hard constraint and never enters the vault.

**Where in the vault:**
- Reusable patterns → `wiki/patterns/<kebab>.md`
- Architectural decisions → `wiki/decisions/<kebab>.md`
- Project context (azure-analyzer specific) → `wiki/projects/azure-analyzer/`
- Cross-repo standards → `global/<kebab>.md`

**Rules:** Follow vault `AGENTS.md` — YAML frontmatter, mandatory `## Related` with 2+ wikilinks, backlinks from 2+ existing notes, kebab-case filenames, never delete (archive instead). Read `global/vault-write-policy.md` for the full policy.

**What still goes in `.squad/`:** repo-specific decisions, agent histories, orchestration logs, session logs. These are local to azure-analyzer and committed with the code. The vault gets the cross-repo distillation, not the duplicate.

**Sync:** `MemoryVaultSync` Scheduled Task picks up vault changes every 15 minutes (allowlist + gitleaks + content-policy gates). Do NOT manually run `vault-sync.ps1` from inside an azure-analyzer session.

**Why:** User request — make memory persistent and cross-repo discoverable in Obsidian. Avoids siloed `.squad/` knowledge.
