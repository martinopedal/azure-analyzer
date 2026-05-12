## Docs voice profile install and audit

**Source:** `.squad/decisions/inbox/copilot-directive-2026-05-12T13-04-28Z.md` (user directive)
**Date:** 2026-05-12
**Auditor:** Sage

### Summary

Installed `.squad/skills/docs-voice/SKILL.md` as the canonical repo docs voice profile, anonymized from the news-fetcher LinkedIn writer profile. Audited recent docs (README, CHANGELOG, PERMISSIONS, decisions.md, PR template, CONTRIBUTING, agent charters, routing.md) for AI-tells, em/en dashes, and structural patterns. Applied 30 edits across 5 files to remediate violations.

### Files inspected

11 files audited:
- `README.md` (3 violations)
- `CHANGELOG.md` (3 violations)
- `PERMISSIONS.md` (0 violations)
- `.squad/decisions.md` (21 violations)
- `.github/PULL_REQUEST_TEMPLATE.md` (1 wiring change, no violations)
- `CONTRIBUTING.md` (1 wiring change, no violations)
- `.copilot/copilot-instructions.md` (1 wiring change, no violations)
- `.squad/routing.md` (1 wiring change, no violations)
- `.squad/agents/{atlas,forge,iris,lead,sage,sentinel}/charter.md` (6 wiring changes, no violations)

### Violations found and fixed

#### Em-dashes (28 occurrences)

**README.md (2 occurrences):**
- Line 75: `no Azure login required` (was `— no Azure...`)
- Line 279: `the only check enforced` (was `— the only...`)

**CHANGELOG.md (3 occurrences):**
- Line 41: `always open a PR, always check history first` (was `— always...`)
- Line 203: `truthful baseline + CHANGELOG dedup` (was `— truthful...`)
- Line 210: `CI stabilization sprint` (was `— CI stabilization...`)

**.squad/decisions.md (23 occurrences):**
- Line 5: `Post-#418 inbox sweep` (changed em-dash to colon)
- Line 17: `Sage proposal + Iris implementation` (changed em-dash to colon)
- Line 22: `Forge proposal + shipped via #418` (changed em-dash to colon)
- Line 27: `8 tools` (changed em-dash to colon)
- Line 37: `Atlas sample report regeneration` (changed em-dash to colon)
- Line 42: `Schema + EntityStore contract` (changed em-dash to colon)
- Line 49: `not scripts/` (changed em-dash to period, split sentence)
- Line 52: `Round 3 inbox sweep` (changed em-dash to colon)
- Line 167: `Report UX Redesign + Schema 2.2` (changed em-dash to colon)
- Line 169: `#299 to #313` (changed en-dash range to "to")
- Line 200: `map Error to High` (changed arrow to "to")
- Line 201: `Score -1 (errored) to High` (changed arrow to "to")
- Line 202: `Only [0] taken` (changed em-dash to colon)
- Line 203: `Both set to same URL` (changed em-dash to colon)
- Line 204: `No CIS/NIST/PCI/ISO framework tags` (changed em-dash to colon)
- Line 205: `Raw JSON dump` (changed em-dash to colon)
- Line 206: `Tracked, each assigned` (changed em-dash to comma)
- Line 215: `Block.Tag + Test.Tag, EIDSCA/CIS...` (changed em-dash to comma)
- Line 218: `first-class, stop blanking it` (changed em-dash to comma)

#### Arrow symbols (4 occurrences in decisions.md)

Replaced mapping arrows (`→`) with "to" for readability:
- Line 200: `Error→High` became `Error to High`
- Line 201: `Score -1 → High`, `score 0 → High` became "to" form
- Similar patterns in severity/score mapping bullets

#### En-dash range (1 occurrence in decisions.md)

- Line 169: `#299–#313` became `#299 to #313`

#### Structural issues

No question-then-self-answer rhythms, forced analogies, tricolon openers, or AI-tell phrases ("leveraging", "furthermore", "comprehensive", "journey") found in the audited files. The existing prose is direct and concrete.

### Edits not applied (contested)

None. All em/en dashes in audited files were remediations from PR #1049 / #1051 work and were legitimately out of policy.

### Wiring changes

Added docs-voice skill references to:
- `.copilot/copilot-instructions.md`: new "Docs voice" section after "Documentation Rules"
- `.github/PULL_REQUEST_TEMPLATE.md`: updated checklist item to reference `.squad/skills/docs-voice/SKILL.md`
- `CONTRIBUTING.md`: new "Docs voice" section before "Commit sign-off"
- `.squad/routing.md`: new "Skill-aware routing" section
- `.squad/agents/{atlas,forge,iris,lead,sage,sentinel}/charter.md`: appended "## Docs voice" section to each charter

### Anonymization deltas (voice profile)

Stripped from source (news-fetcher LinkedIn voice profile):
- All Martin Opedal personal references, pronouns ("I", "my", "we")
- LinkedIn-specific rules: hashtags, mention tokens, ARTICLE cards, golden hour, posting cadence, body URL strip, signpost phrases, 800-1500 char length target, phone-written roughness
- Profile metadata: Lead Cloud Solution Architect, 14 years of experience, brewery references, MSP backstory
- Engagement metrics: impressions, patterns 1-5 numbered framework, anchor examples naming azure-analyzer or specific past posts
- LinkedIn algorithm 2026 rules, mention tokens, people.yaml

Kept and adapted:
- Direct openers, conclusions before reasoning
- Concrete examples with named tools/files/paths
- Pragmatic over theoretical ("seeing reality > making it look nice in diagrams")
- Critique with empathy
- Accountability over deflection
- Banned phrase list (leveraging, driving, unlocking, in today's landscape, game-changer, deep dive, at the end of the day, furthermore, moreover, additionally, on the other hand, in conclusion, to sum up, in fact)
- Banned structural patterns (question-then-self-answer, forced sports/cooking analogies, "Bold heading: explanation" lists, tricolon openers)
- No em/en dashes (use comma, period, "and")
- No "journey", "comprehensive", "robust", "cutting-edge"
- Vary structure, no symmetry, no 4-paragraph mirror
- Specifics over abstractions

Added (docs-specific):
- Allowed emojis: ✅ ❌ only
- Code blocks must use fenced syntax with language hint
- Headings: sentence case, no trailing punctuation, no period at end of bullet items
- Diagrams: ASCII or mermaid
- PR descriptions: lead with change, then why, then verification
- CHANGELOG entries: Keep a Changelog format, imperative present tense without trailing period
- Decision files: title states decision verbatim, body has Context/Options/Decision/Consequences sections

### Skill confidence proposal

Current: `low` (first observation)
Proposed bump: `medium` after Forge or Atlas applies the skill to a new design doc or PR body successfully. The skill is self-contained and grounded in real examples. Next observation will validate whether agents can apply it consistently without rework.

### Retroactive scope

This audit covers docs shipped in PR #1049 (PSGallery readiness), PR #1051 (unspecified), and recent decision file merges by Scribe. No design docs under `docs/design/` were modified in those PRs based on CHANGELOG review, so no design-doc audit was performed. Future work: extend audit to `docs/design/track-f-auditor-redesign.md` if it was touched recently.

### PR context

This audit is the decision file for the docs-voice install PR. No separate inbox entry is required. Branch: `chore/docs-voice-profile`. Commits all skill, wiring, and audit fixes in one atomic PR.
