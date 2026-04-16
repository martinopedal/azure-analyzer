# Ceremonies

> Team meetings that happen before or after work. Each squad configures their own.

## Design Review

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before |
| **Condition** | multi-agent task involving 2+ agents modifying shared systems |
| **Facilitator** | lead |
| **Participants** | all-relevant |
| **Time budget** | focused |
| **Enabled** | ✅ yes |

**Agenda:**
1. Review the task and requirements
2. Agree on interfaces and contracts between components
3. Identify risks and edge cases
4. Assign action items

---

## Retrospective

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | build failure, test failure, or reviewer rejection |
| **Facilitator** | lead |
| **Participants** | all-involved |
| **Time budget** | focused |
| **Enabled** | yes |

**Agenda:**
1. What happened? (facts only)
2. Root cause analysis
3. What should change?
4. Action items for next iteration

---

## Code Review

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before-merge |
| **Condition** | any code PR |
| **Participants** | opus-4.6, goldeneye, gpt-5.3-codex |
| **Gate** | all-approve |
| **Enabled** | yes |

**Process:**
1. All 3 models review independently
2. Parse-check all .ps1 files, verify no ?. syntax
3. Check error handling and CLI tool wrapper compliance
4. All 3 must APPROVE before merge gate opens
