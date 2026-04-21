# Squad Decisions — Archive

Entries older than 30 days, moved from `decisions.md` to keep the active file under 20 KB.

---

## Archived 2026-04-22

### Routing Infrastructure (2024-12-19)
- **Decision:** routing.md uses `## Work Type → Agent` header format
- **Rationale:** Clear separation of concerns and agent dispatch rules
- **Status:** Active (archived for size)

### GitHub Actions Security (2024-12-19)
- **Decision:** All GitHub Actions MUST be SHA-pinned (never use tags)
- **Rationale:** Security hardening; prevents workflow injection attacks
- **Implementation:** Applied across 10 action references in 4 workflows
- **Status:** Active (archived for size)

### Signed Commits Policy (2024-12-19)
- **Decision:** Signed commits NOT required for this repository
- **Rationale:** Breaks GitHub Dependabot and GitHub API commits; solo maintenance model
- **Status:** Active (archived for size)

### Triage Keyword Robustness (2024-12-19)
- **Decision:** Generic keywords in triage (go:needs-research) must be conditional, not unconditional
- **Rationale:** Prevents false-positive labeling; improves signal-to-noise ratio
- **Status:** Active (archived for size)

### Routing Table & Casting Registry Migration (2024-12-19)
- **Decision:** Squad routing infrastructure fully initialized with domain-specific routing table and casting registry
- **Details:**
  - routing.md section header: `## Work Type → Agent` (Ralph parser requirement)
  - 11 work-type mappings covering all agent specializations
  - Module Ownership section added (12 module-to-owner mappings)
  - Casting registry populated with 6 agents marked `legacy_named: true`
- **Commit:** 85d8c5e
- **Status:** Active (archived for size)

### SHA-Pinning + Triage Keyword Routing + Consistency Fixes (2025-01-26)
- **Decision:** (1) SHA-pinned 4 squad workflows (10 action instances); (2) replaced generic triage keywords in workflows and ralph-triage.js with azure-analyzer specialist keywords; (3) removed contradiction in copilot-instructions.md line 49; (4) made `go:needs-research` conditional (only applied to issues routed to Lead or with no domain match).
- **Keywords:** Atlas (`arg`, `kql`, `query`), Iris (`entra`, `identity`, `graph`, `pim`), Forge (`pipeline`, `workflow`, `ci`, `devops`), Sentinel (`security`, `compliance`, `azqr`, `score`), Sage (`research`, `spike`, `investigation`).
- **Impact:** Security (all workflows SHA-pinned), Triage accuracy (route to specialists), Label hygiene (`go:needs-research` only when needed).
- **Status:** Active (archived for size)

### SBOM + Pinned Versions Implementation (#102) (2025-01-01)
- **Decision:** Created separate `install-manifest.json` for supply-chain security (versions, checksums) distinct from `tool-manifest.json` (orchestration). Added CycloneDX 1.5 SBOM generation, SHA-256 verification functions, and CI/release workflow gates.
- **Rationale:** Clean separation of concerns. Package managers (winget/brew) verify checksums; we document delegation via `pinningNote`. Direct downloads use SHA-256 verification. Industry-standard CycloneDX format with GitHub/Docker/CI integration.
- **Key Choices:** Per-platform entries (Windows/macOS use package managers; Linux uses direct downloads). Separate manifest prevents mixing orchestration and supply-chain concerns.
- **Consequences:** Positive: supply-chain transparency on every release, reproducible installs (where possible), CI gate on hash verification. Negative: maintenance burden when tool versions bump (must update SHA-256).
- **Status:** Active (archived for size)
