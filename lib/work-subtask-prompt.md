# Work Subtask Prompt

You have been given a subtask to implement. Task context is provided in two XML tags appended after this prompt:

- `<task-context>` — JSON object containing: `issue_id`, `issue_title`, `subtask_id`, `subtask_title`, `document.url`, and `prior_lessons` (array of `{commit_sha, note}` or null)
- `<subtask-document>` — The unescaped document content describing the task in detail. May be empty if no document exists — in that case, work from the subtask title alone.

## 1. Present Task Information

Display the task to the user:

```
Next Task: $subtask_id

**Title:** $subtask_title

**From Ticket:** $issue_id ($issue_title)

**Task Details:**
$subtask-document content (or "No document - working from checklist title")

**Prior Lessons from This Branch:**
$prior_lessons (each entry shows commit SHA + lesson note) — or "None recorded yet"

Ready to start working on this task!
```

## 2. Implement the Task

1. **Understand the context:**
   - If `prior_lessons` is present and non-null, review each note and factor relevant lessons into implementation
   - Read the files mentioned in the task
   - Review the specific lines referenced
   - Understand what change is being requested

2. **Implement the changes:**
   - Make the requested changes
   - Follow project code style and patterns

## 3. Big Task Mode

If the document content contains multiple actionable items — such as numbered phases, step-by-step lists, tables with items to convert, or multi-part plans — this is a **big task**. The subtask represents the **entire plan**, not just the first item.

**Detection criteria** (any of these indicate a big task):

- Multiple numbered steps or phases (e.g., "Phase 1", "Phase 2", or "1.", "2.", "3.")
- Tables listing multiple items to process (e.g., functions to convert, files to update)
- Checklists with multiple entries
- Documents with more than ~3 distinct actionable items

**Big task behavior:**

1. **Work through ALL items** in the plan document before proceeding to step 4. Do not commit or mark complete after just the first item.
2. **Implement incrementally** — work through items one by one or in logical groups, but do NOT stop and commit partway through.
3. **Stage ALL changes** once every item in the plan is implemented.
4. **Call `ollo complete-subtask` once** with a summary commit message covering all work done.

**Commit message format for big tasks:**

```
<type>(<TICKET_ID>, <SUBTASK_ID>): <summary of all work done>
```

Example:

```bash
git add -A && ollo complete-subtask "SNWLLY-22" "SUBTASK-007" "refactor(SNWLLY-22, SUBTASK-007): convert all orders utils to endpoints"
```

**Important:** The `SUBTASK_ID` must always be included in the commit message alongside the `TICKET_ID`.

## 4. Complete the Task (Single Command)

> **Optimization:** The `ollo complete-subtask` command triggers a git commit, which runs the pre-commit hook (formatting, linting, type checking, and tests). When checking your work before completing a task, skip running these individually — jump straight to `ollo complete-subtask` and let the hook surface any errors. If the hook fails, fix the issues and re-run.

After implementing, run this single command to stage + commit + mark complete:

```bash
git add <files> && ollo complete-subtask "$TICKET_ID" "$SUBTASK_ID" "<commit-message>"
```

The commit message should follow the git-workflow pattern:

```
<type>(<TICKET_ID>, <SUBTASK_ID>): <description>
```

Use the `issue_id` and `subtask_id` from `<task-context>` as `$TICKET_ID` and `$SUBTASK_ID`.

Example:

```bash
git add src/services/orders/api/createOrder.ts && ollo complete-subtask "SNWLLY-22" "SUBTASK-003" "refactor(SNWLLY-22, SUBTASK-003): create outbox messages when orders are created"
```

The script will:

1. Create the commit with Co-Authored-By trailer
2. Mark the subtask as complete in Kota

**Success response:**

```json
{
  "issue_id": "SNWLLY-22",
  "subtask_id": "SUBTASK-003",
  "commit": {
    "sha": "9e56960e",
    "message": "refactor(SNWLLY-22, SUBTASK-003): use switch-case...",
    "status": "created"
  },
  "mark_complete": {
    "status": "completed",
    "error": null
  }
}
```

**No staged changes error:**

```json
{
  "issue_id": "SNWLLY-22",
  "subtask_id": "SUBTASK-003",
  "commit": {
    "status": "no_staged_changes",
    "error": "No staged changes to commit"
  },
  "mark_complete": { "status": "skipped", "error": "No commit created" }
}
```

## Helper Scripts Reference

| Script                                                        | Purpose                            |
| ------------------------------------------------------------- | ---------------------------------- |
| `ollo complete-subtask <TICKET_ID> <SUBTASK_ID> <COMMIT_MSG>` | Commit + mark complete in one call |

## Error Handling

- **No staged changes:** Script returns `{"commit": {"status": "no_staged_changes", ...}}`
- **Document not found:** `document` field will be `null` - proceed with checklist title
