#!/usr/bin/env bash
# Ultra-fast /itemize implementation with pre-gathered context
# Minimizes Claude round trips by gathering all git context upfront
#
# Usage: ollo itemize
# Stage your changes with 'git add' before running this script.

set -euo pipefail

if [[ -z "${OLLO_HOME:-}" ]]; then
  echo "error: OLLO_HOME is not set. Run via 'ollo' dispatcher or set OLLO_HOME." >&2
  exit 1
fi

# --- COLORS ---
DIM='\033[2m'
RESET='\033[0m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'

log() {
  [[ -z "${DEBUG:-}" ]] && return
  local color="$1" message="$2"
  printf "${DIM}[%s]${RESET} ${color}%s${RESET}\n" "$(date +%H:%M:%S)" "$message" >&2
}

# --- HELP FLAG ---
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat >&2 <<'EOF'
Usage: ollo itemize

Generate a ticket and branch for pre-staged changes.
Stage your changes with 'git add' before running this script.

Output:
  Shell commands are printed to stdout; all other output goes to stderr.
  This allows piping: eval "$(ollo itemize)"
EOF
  exit 0
fi

# --- VALIDATE STAGED CHANGES ---
if git diff --cached --quiet; then
  echo "❌ No staged changes found." >&2
  echo "" >&2
  echo "Stage your changes first with 'git add', then run ollo itemize." >&2
  exit 1
fi

# Create temp files for parallel fetches
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Gather git context
{
  echo "=== GIT_STATUS ==="
  git status --short
  echo ""

  echo "=== GIT_DIFF_STAGED_STAT ==="
  git diff --cached --stat 2>/dev/null || echo "(nothing staged)"
  echo ""

  echo "=== GIT_DIFF_STAGED_FULL ==="
  # Limit to 300 lines to avoid overwhelming context
  git diff --cached 2>/dev/null | head -300 || echo "(nothing staged)"
  echo ""

  echo "=== RECENT_COMMITS ==="
  git log --oneline -10 2>/dev/null || echo "(no commits)"
} >"$TEMP_DIR/git-context.txt"

# Read gathered context
GIT_CONTEXT=$(cat "$TEMP_DIR/git-context.txt")

# --- READ SKILLS (local files, fast) ---
PROJECT_ROOT="$(cd "$OLLO_HOME/../.." && pwd)"

GIT_SKILL=""
if [[ -f "$PROJECT_ROOT/.claude/skills/git-workflow/SKILL.md" ]]; then
  GIT_SKILL=$(cat "$PROJECT_ROOT/.claude/skills/git-workflow/SKILL.md")
fi

# --- JSON SCHEMA ---
JSON_SCHEMA='{
  "type": "object",
  "properties": {
    "ticketTitle": {
      "type": "string",
      "description": "Short imperative title for the ticket (5-10 words). Example: Add authentication middleware to API services"
    },
    "ticketDescription": {
      "type": "string",
      "description": "Markdown description for the ticket with Summary, Changes Made, and Context sections"
    },
    "commitMessage": {
      "type": "string",
      "description": "Full commit message following git-workflow skill conventions. First line: type(subject): action. Followed by optional body paragraphs, then the co-authored-by trailer."
    }
  },
  "required": ["ticketTitle", "ticketDescription", "commitMessage"],
  "additionalProperties": false
}'

# --- BUILD PROMPT ---
read -r -d '' PROMPT <<'PROMPT_TEMPLATE' || true
You are executing the /itemize command. ALL context has been pre-gathered for you.
Your task: Output ONLY the structured JSON with ticket title, ticket description, and commit message. No git commands, no explanations, no tool calls.

## Git Workflow Skill
<git-workflow>
__GIT_SKILL__
</git-workflow>

## Git State
__GIT_CONTEXT__

## Instructions

1. Analyze the staged diff to understand what changes will be committed
2. Generate a ticket title:
   - Keep it short (5-10 words)
   - Use imperative mood (e.g., "Add", "Fix", "Update", "Implement")
   - Be specific about what's being done
3. Generate a ticket description in markdown:
   - Include a Summary section (1-2 sentences)
   - Include a Changes Made section (bullet points of key changes)
   - Include a Context section (why these changes are needed)
4. Generate a commit message following git-workflow skill conventions:
   - First line format: `<type>(<subject>): <action>`
   - Do NOT include a ticket ID in the subject (the ticket hasn't been created yet)
   - Include optional body paragraphs if the changes warrant it
   - End with the co-authored-by trailer

## Commit Message Trailer

Always end the commit message with:

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>

## Output Format

Output ONLY valid JSON matching the provided schema. No markdown, no code fences, no explanations.
PROMPT_TEMPLATE

# Substitute variables
PROMPT="${PROMPT//__GIT_SKILL__/$GIT_SKILL}"
PROMPT="${PROMPT//__GIT_CONTEXT__/$GIT_CONTEXT}"

# --- CALL CLAUDE WITH JSON SCHEMA ---
log "$CYAN" "Analyzing staged changes..."

# Save prompt to file (too long for command line argument)
echo "$PROMPT" >"$TEMP_DIR/prompt.txt"

log "$DIM" "Running claude..."
if ! claude --setting-sources "" --model sonnet --output-format json --json-schema "$JSON_SCHEMA" --verbose -p "$(cat "$TEMP_DIR/prompt.txt")" >"$TEMP_DIR/claude-output.txt" 2>&1; then
  log "$RED" "Claude exited with error"
  cat "$TEMP_DIR/claude-output.txt" >&2
  exit 1
fi

# --- PARSE JSON OUTPUT ---
# --output-format json produces a JSON array of event objects.
# The structured output is in the "result" event under .structured_output
RESULT_JSON=$(jq -r '.[] | select(.type == "result") | .structured_output // empty' "$TEMP_DIR/claude-output.txt" 2>/dev/null)

if [[ -z "$RESULT_JSON" ]]; then
  log "$RED" "Failed to parse structured output from Claude"
  echo "❌ Failed to parse Claude output. Raw output:" >&2
  cat "$TEMP_DIR/claude-output.txt" >&2
  exit 1
fi

# Extract fields
TITLE=$(echo "$RESULT_JSON" | jq -r '.ticketTitle')
DESCRIPTION=$(echo "$RESULT_JSON" | jq -r '.ticketDescription')
COMMIT_MESSAGE=$(echo "$RESULT_JSON" | jq -r '.commitMessage')

if [[ -z "$TITLE" || "$TITLE" == "null" ]]; then
  echo "❌ Missing ticket title in Claude output" >&2
  exit 1
fi

if [[ -z "$COMMIT_MESSAGE" || "$COMMIT_MESSAGE" == "null" ]]; then
  echo "❌ Missing commit message in Claude output" >&2
  exit 1
fi

log "$GREEN" "Generated ticket: $TITLE"

# --- OUTPUT SHELL COMMANDS TO STDOUT ---
# The commit message subject has format: type(subject): action
# The output script will interpolate the ticket ID: type(TICKET-XXX, subject): action
cat <<EOF
TICKET_FILE=\$(mktemp)
kota tickets create --title "\$(cat <<'TITLE'
$TITLE
TITLE
)" --description "\$(cat <<'DESCRIPTION'
$DESCRIPTION
DESCRIPTION
)" > "\$TICKET_FILE"
TICKET_ID=\$(jq -r '.identifier' "\$TICKET_FILE")
TICKET_BRANCH_NAME=\$(jq -r '.branchName' "\$TICKET_FILE")
rm "\$TICKET_FILE"
COMMIT_MSG=\$(cat <<'COMMIT_MSG'
$COMMIT_MESSAGE
COMMIT_MSG
)
COMMIT_MSG=\$(echo "\$COMMIT_MSG" | sed "1 s/^\\([a-z]*\\)(\\(.*\\)):/\\1(\$TICKET_ID, \\2):/")
git-spice branch create "\$TICKET_BRANCH_NAME" -m "\$COMMIT_MSG"
EOF
