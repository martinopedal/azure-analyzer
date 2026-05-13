# Skill: Codebase Consistency Audit

**Confidence:** medium (validated once on azure-analyzer post-BUG-1)

## When to use

Run this audit pattern after any shipped bug that the test suite missed, or periodically (quarterly) to prevent contract drift.

## Seven-stream audit framework

Each stream is independent and can be parallelized across agents.

### Stream A: Contract ratchet validation
- Run any existing ratchet tests with `-Output Detailed`
- For each contract: compare baseline (what the test allows) vs actual (what the code does)
- Check for regex blind spots (typed exceptions, bare re-throws, indirect patterns)
- Flag loose baselines (baseline allows N when actual is N-X)

### Stream B: Schema/normalizer consistency
- Walk every normalizer: does it use the canonical emit function?
- Verify enum values (severity, entity type) against the schema source of truth
- Verify canonical ID functions are used for identity entities
- Check error categories against the enum

### Stream C: Manifest vs reality
- Forward check: every enabled manifest entry has a wrapper, normalizer, and tests
- Reverse check: every wrapper is registered in the manifest
- Generated artifacts match current manifest state

### Stream D: Sanitization coverage
- Inventory every output sink (file writes, exports, serialization)
- Verify each runs through the sanitization function before write
- Flag partial sanitization (string-only scrubbing that misses nested objects)

### Stream E: Test false-pass patterns
- Flag `Should -Match` on rendered output without paired upstream null-guards
- Flag assertions that pass on `@($null)` collections
- Catalog `-Skip`/`-Pending` tests not tied to issues
- Flag heavy mocking that bypasses the data path being claimed-tested
- Assess grandfathered baselines: how loose are they?

### Stream F: Documentation generator freshness
- Run each generator in check-only mode
- Verify CI workflow invokes each generator's freshness check

### Stream G: CI gate audit
- List required vs running-but-not-required checks
- Recommend which should become required based on risk

## Deliverable format

Single markdown file with:
1. Executive summary (counts by severity, top 5 priorities, effort buckets)
2. One section per stream with tables
3. Recommended follow-up issues with title, labels, effort, parallelism notes
4. Out-of-scope section (what other agents are covering)

## Anti-patterns to avoid

- Don't modify code during an audit. Output is a report only.
- Don't duplicate work another agent is actively doing. Check branch/scope assignments first.
- Don't flag style issues. Focus on correctness, safety, and contract compliance.
- Don't run the full test suite if you only need to read the test code. Audit the assertions, not the execution.
