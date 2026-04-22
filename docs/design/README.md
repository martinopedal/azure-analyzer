# Design Proposals

This directory holds design proposals and architectural sketches for azure-analyzer features that are in flight or under discussion.

Use this space for:

- Pre-implementation design docs that need team review before code lands
- Architecture sketches and trade-off notes for new tools, normalizers, or report features
- Spike write-ups that may or may not graduate to a full implementation

Once a design is implemented, move the canonical reference into the appropriate section under `docs/architecture/`, `docs/reference/`, or `docs/guides/`, and link back here from the implementation PR.

## Conventions

- One design per file. Use a short kebab-case slug as the filename, e.g. `policy-viz-graph.md`.
- Lead with a problem statement and the constraints, not the proposed solution.
- Include an explicit "Status" line at the top: `Status: Draft | In Review | Accepted | Implemented | Superseded`.
- Reference any related issues, PRs, or ADRs under `docs/decisions/`.

The Docs Check workflow treats updates under `docs/design/` as valid documentation alongside code changes, so design proposals can land in the same PR as scaffold or prototype code without tripping the CI gate.
