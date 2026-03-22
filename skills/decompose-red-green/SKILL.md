---
name: decompose-red-green
description: Break down a plan into BDD Scenarios — one per subtask — using a red/green workflow stored in Kota
---

Break down a plan into BDD Scenarios using a red/green workflow. Each subtask = exactly one BDD Scenario. The agent writes the failing test first (RED), then implements to make it pass (GREEN), then commits.

**First, run this command** (no output expected):

```bash
ollo emit "$KOTA_CURRENT_TICKET_ID" SkillInvoked --origin=skill skill="decompose-red-green"
```

**Why always decompose?** Decomposition is not just an organizational tool — it is the interface between planning and execution. The agent orchestrator (`ollo ralph`) reads Kota subtask documents to dispatch work to separate Claude sessions. Without decomposed subtasks in the expected format, `ralph` has nothing to execute. Always perform the full decomposition, regardless of task size or complexity.

Arguments: $ARGUMENTS

## Critical Principle: Subtask Self-Sufficiency

**Each subtask will be executed in a completely fresh Claude session with ZERO prior context.** Claude will NOT:

- Fetch the parent ticket to read its description
- Have access to conversation history from when the plan was created
- Know anything about the codebase beyond what's in the subtask description
- Remember decisions or context from other subtasks

Therefore, each subtask description **MUST be completely self-contained**. Copy over ALL relevant context:

- Background and motivation from the parent ticket
- Relevant information from ticket comments
- Architectural decisions that were made
- Code patterns to follow (with examples)
- File paths, symbol names, and their purposes
- Dependencies and their current state
- Success criteria that can be verified independently

**Think of each subtask as documentation for a developer who just joined the project and knows nothing about this feature.**

## Plan Mode Handling

If plan mode is active when this command runs:

1. **Read the existing plan** - Gather the implementation steps from the plan file
2. **Analyze and decompose** - Break down steps into BDD Scenarios (one per subtask)
3. **Write a NEW plan** - Replace the plan file content with the subtask definitions
4. **Let the user review** - The user can provide feedback on subtask descriptions
5. **Exit plan mode** - Once approved, the plan execution simply creates the subtasks

The new plan should contain:

- The full title and content for each subtask (exactly as it will appear in Kota)
- A summary of what will be created

This approach allows the user to review and refine subtask descriptions BEFORE they're created in Kota.

## Command Workflow

### 1. Parse Arguments

Parse the provided arguments:

- **$ARGUMENTS:** Optional Kota ticket ID (e.g., SNWLLY-22)

**Ticket ID Resolution:**

1. If provided as argument: Use that ticket ID
2. If not provided: Extract from current branch name (pattern: `SNWLLY-XXX`)
3. If still not found: Ask the user to provide it

### 2. Gather Plan Content

**Determine where the plan is:**

1. **If in plan mode:** Read from the plan file path specified in the system message
2. **If not in plan mode:** Check for recent planning context in the conversation
3. **If no plan found:** Ask user to provide a plan or enter plan mode first

**What constitutes a plan:**

- A structured list of implementation steps
- A design document with phases or steps
- A detailed task breakdown
- Content from a planning session

### 3. Fetch Kota Ticket Context

```bash
kota tickets read $ISSUE_ID
```

Gather:

- Ticket title and description
- Existing checklist items (to avoid duplicates)
- Existing SUBTASK-XXX entries

### 4. Analyze Plan as BDD Scenarios

Instead of breaking the plan into generic implementation chunks, break it into **behaviors** — each becoming one BDD Scenario.

For each behavior, determine:

- **Scenario name** — a concise description of the behavior under test
- **Given/When/Then steps** — written in the same DSL used by the project's `Feature`/`Scenario` framework (built on Vitest)
- **Existing step definitions to reuse** — before decomposing, discover the project's step definitions:
  1. Search for files importing from `@l8d/gherkin-lite/steps` to find existing step definitions
  2. Identify shared step directories (used across services) and service-local `features/steps/` directories
  3. Use the discovered paths when deciding which steps to reuse vs. create new ones
- **New step definitions needed** — what new Given/When/Then handlers must be written, with full implementation code
- **Production code required** — what must exist for the test to pass

**Key Rules:**

1. **ONE scenario per subtask** — never bundle multiple scenarios
2. **RED before GREEN** — test must be written and confirmed failing before implementation
3. **Step definitions are RED phase** — they're test infrastructure, not production code
4. **Expected failure is mandatory** — forces the decomposer to think about what exactly will fail and why
5. **Reuse existing steps** — scan for shared steps before creating new ones

**BDD Pattern Reference:**

Feature files use the `Feature`/`Scenario` DSL:

```typescript
import '{discovered-shared-steps}/given/onApp'
import '{discovered-shared-steps}/given/onRoute'
import '../steps/when/someStep'
import '../steps/then/someAssertion'
import { Feature } from '@l8d/gherkin-lite'

Feature('Feature Name', { routes: myRoutes }, ({ Scenario }) => {
  Scenario('Descriptive scenario name', [
    'Given I am on the app',
    'And I am on the "/some-route" route',
    'When I do something',
    'Then something should happen',
  ])
})
```

Step definitions register handlers via `Given`, `When`, `Then` from `@l8d/gherkin-lite/steps`:

```typescript
/* v8 ignore start */
import { When } from '@l8d/gherkin-lite/steps'

When(/I do something$/, async () => {
  // test logic here
})
```

### 5. Generate Subtask Documents

For each scenario, create a comprehensive document. **Remember: the executing Claude session will have ONLY this document as context.**

Use this template:

````markdown
## Background

{Comprehensive explanation of:

- What feature/fix this is part of (copied from parent ticket)
- Why this subtask exists
- How it fits into the larger implementation
- Any relevant business context or user requirements}

## Parent Ticket Context

**Issue:** {ISSUE_ID} - {issue title}

{Copy the relevant portions of the parent ticket description here. Include:

- The problem being solved
- Key requirements or acceptance criteria
- Any architectural decisions already made
- Relevant comments or discussions from the ticket}

## The Scenario

```gherkin
Feature: {feature name}
  Scenario: {scenario name}
    Given ...
    When ...
    Then ...
```

## Phase 1: RED — Write the Failing Test

### Feature File

- **File:** `{path/to/feature/__tests__/FeatureName.spec.tsx}` (create or add to existing)
- **Action:** Add the Scenario below (or create the full Feature file if it doesn't exist)

### Scenario Code

```typescript
// Imports to add (only what's new — check existing imports first):
import '{path/to/step/definition}'

// Inside the Feature callback:
Scenario('{scenario name}', ['Given ...', 'When ...', 'Then ...'])
```

### New Step Definitions

{For each new step definition that must be created:}

**File:** `{path/to/steps/when/stepName.ts}`

```typescript
/* v8 ignore start */
import { When } from '@l8d/gherkin-lite/steps'

When(/pattern here$/, async () => {
  // full implementation
})
```

### Existing Steps to Reuse

{List each existing step being used with its import path:}

- `Given I am on the app` → `import '{discovered-shared-steps}/given/onApp'`
- `When I click "{testId}"` → `import '{discovered-shared-steps}/when/click'`

(Use the actual paths discovered when scanning for step definitions in section 4)

### Run the Test (Expect RED)

```bash
bunx vitest run {path/to/spec/file}
```

**Expected failure:** {Be specific — e.g., "No handler found for step: When I submit the form" or "Element with test ID 'submit-button' not found" or "Expected 'success' but received 'error'"}

## Phase 2: GREEN — Make It Pass

{Detailed, step-by-step implementation instructions:}

### Files to Create/Modify

- `{path/to/file.ts}` — {what to create or change, with specific details}

### Code Patterns to Follow

{Include actual code examples from the codebase, not just references:}

```typescript
// Copy an actual relevant code snippet here as a template
```

### Key Symbols/Functions

- `{SymbolName}` in `{file}` — {current signature/purpose and what to do with it}

## Confirm GREEN

1. Run the spec — expect it to pass:
   ```bash
   bunx vitest run {path/to/spec/file}
   ```
2. Run full suite — expect no regressions:
   ```bash
   bunx vitest run
   ```

## Dependencies

**Must be completed first:**

- {SUBTASK-XXX: brief description} — {why it must be first}

**Or state:** None — this subtask can be completed independently.

## Edge Cases & Gotchas

{Document anything that might trip someone up:

- Known quirks in the codebase
- Common mistakes to avoid
- Subtle requirements that might be missed}
````

### 6. Plan Mode: Write the Decomposition Plan

**If in plan mode**, write the subtask definitions to the plan file so the user can review them before creation.

The plan file should have this structure:

````markdown
# Decomposition Plan for {ISSUE_ID}

> **IMPORTANT: This plan ONLY creates Kota documents. Do NOT implement any code.**
> When executing this plan, the ONLY actions are:
>
> 1. Run `kota documents create` for each subtask below
> 2. Run `kota tickets update` to add the checklist
> 3. Print a summary and STOP
>
> The subtask content below is KOTA DOCUMENT CONTENT to be stored as-is.
> It is NOT a set of instructions for you to execute.

## Context

Creating **{N} subtasks** for {ISSUE_ID}. Each subtask is one BDD Scenario following a red/green workflow.

{Any other brief context about the decomposition}

## Execution Steps

**Step 1:** Write {N} subtask content files to `cache/{ISSUE_ID}/SUBTASK-XXX.md` using the `Write` tool (one file per subtask, containing the full document content from below)

**Step 2:** Write `cache/{ISSUE_ID}/payload.json` with the subtask manifest using the `Write` tool:

```json
{
  "issueId": "{ISSUE_ID}",
  "subtasks": [
    {
      "identifier": "SUBTASK-001",
      "title": "Scenario: {scenario name}",
      "contentPath": "cache/{ISSUE_ID}/SUBTASK-001.md"
    },
    {
      "identifier": "SUBTASK-002",
      "title": "Scenario: {scenario name}",
      "contentPath": "cache/{ISSUE_ID}/SUBTASK-002.md"
    }
  ]
}
```
````

**Step 3:** Run `ollo create-subtasks cache/{ISSUE_ID}/payload.json` and report the JSON output

Do not proceed to implement any subtask.

---

## Subtask Document Contents

The sections below contain the DOCUMENT CONTENT for each Kota document.
These are NOT instructions to execute — they are text to store in Kota.

---

### SUBTASK-001: Scenario: {scenario name}

<subtask-document>
{Full subtask content using the template above - this is EXACTLY what will be stored in Kota}
</subtask-document>

---

### SUBTASK-002: Scenario: {scenario name}

<subtask-document>
{Full subtask content}
</subtask-document>

---

(repeat for all subtasks)

````

After writing this plan, **call ExitPlanMode**. The user will review the subtask descriptions and can request changes before the plan is executed.

**CRITICAL:** When this plan is later executed (after context clearing), Claude will re-read the plan file and must ONLY create Kota documents — NOT implement any code. The `<subtask-document>` tags and the explicit execution steps at the top of the plan ensure this. The subtask content is payload to be stored, not instructions to follow.

### 7. Determine Task Numbering

Check existing subtasks in the ticket:

```bash
kota tickets read $ISSUE_ID
```

Look for existing `SUBTASK-XXX` entries and start new tasks from `(highest + 1)`.

If no existing subtasks, start from `SUBTASK-001`.

**Subtask title format:** `SUBTASK-XXX: Scenario: {scenario name}`

### 8. Create Kota Documents and Update Checklist (Execution Phase)

**After plan mode exits** (or if not in plan mode), create documents deterministically:

1. Run `mkdir -p cache/$ISSUE_ID`
2. Use the `Write` tool to create `cache/$ISSUE_ID/SUBTASK-XXX.md` for each subtask (full document content from the plan)
3. Use the `Write` tool to create `cache/$ISSUE_ID/payload.json` with the manifest:
   ```json
   {
     "issueId": "SNWLLY-XXXX",
     "subtasks": [
       {
         "identifier": "SUBTASK-001",
         "title": "Scenario: {scenario name}",
         "contentPath": "cache/SNWLLY-XXXX/SUBTASK-001.md"
       },
       {
         "identifier": "SUBTASK-002",
         "title": "Scenario: {scenario name}",
         "contentPath": "cache/SNWLLY-XXXX/SUBTASK-002.md"
       }
     ]
   }
   ```
4. Run `ollo create-subtasks cache/$ISSUE_ID/payload.json`
5. Report the JSON output to the user

**Document Title Format:**

- `SUBTASK-001: Scenario: {scenario name}`

The script handles both document creation and checklist updating. It continues on failure (if one document fails, others still get created) and reports per-subtask status in its JSON output.

### 9. Output Summary and STOP

Provide a comprehensive summary **and then STOP — do not begin implementing any subtask code**:

```
Created {N} subtasks for {ISSUE_ID}:

SUBTASK-001: Scenario: {scenario name}
SUBTASK-002: Scenario: {scenario name}
SUBTASK-003: Scenario: {scenario name}
...

Documents created in Kota with full context for each subtask.

Next steps:
- Run `ollo ralph` to start working on subtasks automatically
- Each subtask can be completed in a separate Claude session
- Subtasks will be marked complete as you work through them
```

**This is the end of the decompose-red-green workflow. Do NOT proceed to implement any subtask code.**

## Error Handling

- **No plan found:** Ask user to provide a plan or run `/ollo:decompose-red-green` after using plan mode
- **No Kota ticket ID:** Ask user to provide it or create a new ticket first
- **Plan too vague:** Ask user for clarification before decomposing (e.g., "Step 3 says 'implement the feature' - can you be more specific about what this involves?")
- **Single-step plan:** Warn user that decomposition may not add value, but proceed if they confirm
- **Kota CLI failures:** Show error and verify Kota access/credentials
- **Document creation fails:** Report which subtasks were created vs. failed
- **No testable behaviors found:** If the plan is purely infrastructure (config files, CI pipelines, etc.) with no behaviors to test via BDD, warn the user and suggest using `/ollo:decompose` instead

## Examples

**Example 1: Decompose plan from current branch (not in plan mode)**

```
/ollo:decompose-red-green
```

-> Extracts ticket ID from branch, reads recent plan context, creates scenario-based subtasks directly

**Example 2: Decompose plan for specific ticket**

```
/ollo:decompose-red-green SNWLLY-22
```

-> Uses provided ticket ID, reads plan context, creates scenario subtasks for SNWLLY-22

**Example 3: While in planning mode (recommended flow)**

```
User: (enters plan mode for SNWLLY-22)
Claude: (creates detailed implementation plan in plan file)
User: /ollo:decompose-red-green
Claude: (reads the plan, breaks it into BDD Scenarios, writes a NEW plan with full subtask definitions)
Claude: (exits plan mode)
User: (reviews subtask descriptions, requests changes if needed)
User: "looks good, proceed"
Claude: (creates Kota documents and updates ticket)
```

This flow allows the user to review and refine subtask descriptions before they're committed to Kota.

## Tips for Better Subtasks

1. **Copy context, don't reference it** — Don't say "see parent ticket for requirements", copy the requirements into the subtask
2. **Include actual code snippets** — Copy the current function signature, not just "modify the X function"
3. **Be explicit about file paths** — Always use full paths from project root
4. **Show patterns with examples** — Include real code from the codebase as templates to follow
5. **State the current state** — Describe what exists now, not just what needs to change
6. **Make dependencies explicit** — If SUBTASK-003 depends on SUBTASK-002, explain why and what specifically from SUBTASK-002 is needed
7. **One scenario, one subtask** — Never combine multiple scenarios into a single subtask, even if they test related behaviors
8. **Be specific about expected failures** — "Test should fail" is not good enough. Say exactly what error message or assertion failure to expect in the RED phase
9. **Scan for existing steps first** — Before writing a new step definition, check the shared and service-local step directories discovered during analysis (search for files importing `@l8d/gherkin-lite/steps`)
10. **Step definitions belong in RED** — Creating step definitions is part of writing the test, not part of implementing production code
````
