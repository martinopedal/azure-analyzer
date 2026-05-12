---
name: "docs-voice"
description: "Write repository documentation in the house voice: direct, concrete, no AI-tells, only ✅ ❌ emojis"
domain: "documentation"
confidence: "low"
source: "manual (anonymized from LinkedIn voice profile, first observation)"
---

## Context

All repository documentation (README, CHANGELOG, PERMISSIONS, design docs, PR bodies, decision files, agent histories) must follow this voice profile. Applies to any prose written in committed markdown files visible to readers.

## Voice patterns

Direct openers. State the position or observation first without warming up. Do not use filler phrases ("In today's world", "As we all know", "I'm excited to share"). Get to the point.

Conclusions before reasoning. Give the answer first, then explain why. Do not build up to a reveal. The reader knows where you stand immediately.

Concrete examples over abstractions. Name specific tools, files, paths, and technologies. Do not talk in abstractions when you can point to something real. "Karpenter subnet sizing" beats "Kubernetes networking".

Pragmatic over theoretical. Seeing reality is more important than making it look nice in diagrams. Value what works in production over what looks good on paper.

Critique with empathy. When challenging an approach, acknowledge why it exists before explaining why it falls short. "Restrictive policy is correct. But without a process for..." not "This is wrong because...".

Accountability over deflection. When something fails, say so plainly. Do not hide behind passive voice. "The wrapper failed to handle..." not "Failures were observed...".

Vary structure. Do not use the same paragraph length or format throughout. Mix one long detailed paragraph, then a short punchy line, then a medium one. The reader should not be able to predict the shape of the next paragraph. Ban 4-paragraph symmetry. No uniform section structure.

## Banned phrases

These are AI-tells. Never use them:

- leveraging, driving, unlocking
- in today's landscape, game-changer, deep dive
- at the end of the day, it goes without saying
- furthermore, moreover, additionally, on the other hand
- in conclusion, to sum up, in fact
- journey (for career or project progression)
- comprehensive, robust, cutting-edge
- feel free to connect, if you found this helpful, drop a comment if this resonated

## Banned structural patterns

These survive even when the phrase blacklist is clean:

- No question-then-self-answer paragraph rhythm. "But what does this actually mean? Let's dive in." is the canonical AI rhythm. If you ask a question, leave it open or have the next paragraph stake a position.
- No forced analogies comparing technical work to sports, cooking, or marathons. "Much like running a marathon, deploying a Landing Zone takes pacing." Cut it.
- No "Bold heading: explanation" paragraph pattern. ("**Speed**: faster pipelines. **Scale**: more nodes. **Stability**: fewer alerts.").
- No tricolon openers. ("Faster. Cheaper. Smarter."). Open with a specific moment instead.

## Formatting rules

- Allowed emojis: only ✅ (U+2705 CHECK MARK BUTTON) and ❌ (U+274C CROSS MARK). No other emojis in committed docs. (🔧 🏗️ 📋 🎉 🚀 🔄 🔍 are coordinator UI affordances, not doc content.)
- No em dashes or en dashes. Use commas, periods, or "and" instead.
- Code blocks must use fenced syntax with language hint.
- Headings: sentence case, no trailing punctuation.
- No period at end of bullet items.
- Diagrams: ASCII or mermaid. No decorative emoji-heavy art.

## PR descriptions

Lead with the change in one sentence, then the why, then verification steps. No filler opening paragraph.

Example:
```
Installs the docs-voice profile and audits recent prose for AI-tells. 
Applies the directive from copilot-directive-2026-05-12T13-04-28Z 
(no AI language, only checkmarks and crosses). Remediates violations in 
README, CHANGELOG, PERMISSIONS, decisions.md.

Files changed:
- Skill: .squad/skills/docs-voice/SKILL.md
- Wiring: .copilot/copilot-instructions.md, PR template, agent charters
- Audit fixes: README.md (3 em-dashes), CHANGELOG.md (2 AI-tells), ...

Verification: grep for em-dashes, grep for banned phrases.
```

## CHANGELOG entries

Follow Keep a Changelog format. Subject line is imperative present tense without trailing period.

Example:
```
- docs: install repo-wide docs voice profile and remediate recent prose (#963 follow-up)
```

Not:
```
- Documentation: We have installed a new docs voice profile.
```

## Decision files

Title states the decision verbatim. Body has Context / Options considered / Decision / Consequences sections. No filler introduction.

Example:
```
## 2026-05-12 — Docs voice profile mandatory

### Context
User directive: all docs must follow the anonymized LinkedIn voice profile.
No AI-tells, only checkmarks and crosses.

### Decision
Install .squad/skills/docs-voice/SKILL.md as canonical reference.
All agents apply it to committed docs.

### Consequences
- Retroactive audit of recent PRs required
- Agent charters link to the skill
- PR template adds docs-voice checklist item
```

## Examples

Good:
```
Wrapper emits tool version + evidence paths. Normalizer maps all Schema 2.2 
fields through New-FindingRow.
```

Bad:
```
Leveraging the comprehensive wrapper, we're excited to share that the 
normalizer now drives enhanced Schema 2.2 field mapping through 
New-FindingRow — unlocking robust end-to-end ETL capabilities.
```

Good:
```
PSGallery ships only the orchestrator and report renderers. Every external 
scanner is a soft dependency and is fetched on demand by the manifest-driven 
installer at first run.
```

Bad:
```
We're thrilled to announce that PSGallery now offers a cutting-edge 
installation experience! Furthermore, all external scanners are 
comprehensively managed as soft dependencies. 🎉
```

Good:
```
Timeout standardization (#974): Wrapped external CLI invocations in 
Invoke-WithTimeout (300s default) across 9 wrappers. Prevents hung CLI 
processes from blocking the orchestrator indefinitely.
```

Bad:
```
In today's landscape, timeout issues can be a real game-changer when it 
comes to CLI reliability. That's why we took a deep dive into 
standardization, leveraging Invoke-WithTimeout to unlock robust process 
management. At the end of the day, this drives better orchestrator 
stability.
```

## Anti-Patterns

What to avoid:

- Warming up with context-setting paragraphs before stating the point
- Using passive voice to hide accountability ("The test was failing" vs "The test failed")
- Numbered list format where every paragraph follows "first this, then this, finally this"
- Generic open-ended questions as CTAs ("Has anyone tried it?", "What do you think?", "Thoughts?")
- Marketing copy disguised as technical documentation
- Symmetrical paragraph lengths or mirror-image section structures

## Testing the skill

Before finalizing any doc change, check:

1. Does the first sentence state the point without warming up?
2. Is there at least one specific technical detail (tool name, file path, parameter, command)?
3. Is it free of em dashes, unauthorized emojis, and AI-sounding phrases?
4. Would a reader think "this person knows their stuff" not "this reads like ChatGPT"?
5. Are checkmarks (✅) and crosses (❌) the only emojis used?
