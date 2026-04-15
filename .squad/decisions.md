# Squad Decisions

## Active Decisions

### Routing Infrastructure (2024-12-19)
- **Decision:** routing.md uses `## Work Type → Agent` header format
- **Rationale:** Clear separation of concerns and agent dispatch rules
- **Status:** Active

### GitHub Actions Security (2024-12-19)
- **Decision:** All GitHub Actions MUST be SHA-pinned (never use tags)
- **Rationale:** Security hardening; prevents workflow injection attacks
- **Implementation:** Applied across 10 action references in 4 workflows
- **Status:** Active

### Signed Commits Policy (2024-12-19)
- **Decision:** Signed commits NOT required for this repository
- **Rationale:** Breaks GitHub Dependabot and GitHub API commits; solo maintenance model
- **Status:** Active

### Triage Keyword Robustness (2024-12-19)
- **Decision:** Generic keywords in triage (go:needs-research) must be conditional, not unconditional
- **Rationale:** Prevents false-positive labeling; improves signal-to-noise ratio
- **Status:** Active

### Routing Table & Casting Registry Migration (2024-12-19)
- **Decision:** Squad routing infrastructure fully initialized with domain-specific routing table and casting registry
- **Details:**
  - routing.md section header: `## Work Type → Agent` (Ralph parser requirement)
  - 11 work-type mappings covering all agent specializations
  - Module Ownership section added (12 module-to-owner mappings)
  - Casting registry populated with 6 agents marked `legacy_named: true`
- **Commit:** 85d8c5e
- **Status:** Active

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
