#!/usr/bin/env bash
# Ultra-fast /capture implementation with pre-gathered context
# Minimizes Claude round trips by gathering all git/ticket context upfront
#
# Usage: ollo capture [TICKET_ID]
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
Usage: ollo capture [TICKET_ID]

Generate a commit message for pre-staged changes.
Stage your changes with 'git add' before running this script.

Arguments:
  TICKET_ID   Optional ticket ID (e.g. PROJ-12). Auto-detected from branch if omitted.

Output:
  Commit message is printed to stdout; all other output goes to stderr.
  This allows piping: git commit -m "$(ollo capture)"
EOF
  exit 0
fi

# --- PARSE ARGUMENTS ---
TICKET_ID=""

# Check if first arg looks like a ticket ID (PREFIX-NNN)
TICKET_SUPPLIED=false
if [[ "${1:-}" =~ ^[A-Z]+-[0-9]+$ ]]; then
  TICKET_ID="$1"
  TICKET_SUPPLIED=true
fi

# --- GATHER GIT CONTEXT ---
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Extract ticket from branch if not provided
if [[ -z "$TICKET_ID" && "$BRANCH" =~ ([A-Z]+-[0-9]+) ]]; then
  TICKET_ID="${BASH_REMATCH[1]}"
fi

# --- VALIDATE STAGED CHANGES ---
if git diff --cached --quiet; then
  echo "❌ No staged changes found." >&2
  echo "" >&2
  echo "Stage your changes first with 'git add', then run ollo capture." >&2
  exit 1
fi

# Create temp files for parallel fetches
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Parallel git operations
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
} >"$TEMP_DIR/git-context.txt" &
GIT_PID=$!

# Fetch ticket in parallel (if we have an ID)
if [[ -n "$TICKET_ID" ]]; then
  {
    echo "=== TICKET ==="
    # Get ticket details as JSON
    kota tickets read "$TICKET_ID" 2>/dev/null || echo '{"error": "Failed to fetch ticket"}'
  } >"$TEMP_DIR/ticket-context.txt" &
  TICKET_PID=$!
else
  echo '=== TICKET ===' >"$TEMP_DIR/ticket-context.txt"
  echo '{"error": "No ticket ID found"}' >>"$TEMP_DIR/ticket-context.txt"
  TICKET_PID=""
fi

# Wait for parallel fetches
wait $GIT_PID
[[ -n "${TICKET_PID:-}" ]] && wait $TICKET_PID

# Read gathered context
GIT_CONTEXT=$(cat "$TEMP_DIR/git-context.txt")
TICKET_CONTEXT=$(cat "$TEMP_DIR/ticket-context.txt")

# --- READ SKILLS (local files, fast) ---
PROJECT_ROOT="$(cd "$OLLO_HOME/../.." && pwd)"

GIT_SKILL=""
if [[ -f "$PROJECT_ROOT/.claude/skills/git-workflow/SKILL.md" ]]; then
  GIT_SKILL=$(cat "$PROJECT_ROOT/.claude/skills/git-workflow/SKILL.md")
fi

# --- BUILD PROMPT ---
read -r -d '' PROMPT <<'PROMPT_TEMPLATE' || true
You are executing the /capture command. ALL context has been pre-gathered for you.
Your task: Output ONLY the commit message. No git commands, no explanations, no tool calls.

## Git Workflow Skill
<git-workflow>
__GIT_SKILL__
</git-workflow>

## Current Context
- **Branch:** __BRANCH__
- **Ticket ID:** __TICKET_ID__

## Git State
__GIT_CONTEXT__

## Ticket
__TICKET_CONTEXT__

## Instructions

1. Analyze the staged diff to understand what changes will be committed
2. Generate commit message following git-workflow skill:
   - Format: `<type>(<ticket-id>, <subject>): <action>`
   - Use imperative tense for action
   - Include ticket ID from branch/context

3. Output ONLY the commit message text. The parent script will handle the git command.

## Output Format

Output the commit message as plain text with real newlines (not \n escape sequences):

<subject line>

<optional body paragraphs>

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>

IMPORTANT: Output ONLY the commit message. No markdown, no code fences, no explanations.
PROMPT_TEMPLATE

# Substitute variables
PROMPT="${PROMPT//__BRANCH__/$BRANCH}"
PROMPT="${PROMPT//__TICKET_ID__/${TICKET_ID:-"(none - check branch name)"}}"
PROMPT="${PROMPT//__GIT_SKILL__/$GIT_SKILL}"
PROMPT="${PROMPT//__GIT_CONTEXT__/$GIT_CONTEXT}"
PROMPT="${PROMPT//__TICKET_CONTEXT__/$TICKET_CONTEXT}"

# --- CALL CLAUDE WITH STREAMING ---
log "$CYAN" "Gathering context for ${TICKET_ID:-"(no ticket)"} on branch $BRANCH"

# Save prompt to file (too long for command line argument)
echo "$PROMPT" >"$TEMP_DIR/prompt.txt"

# Run Claude with streaming JSON output
# Capture raw output first for debugging
log "$DIM" "Running claude..."
if ! claude --setting-sources "" --output-format stream-json --verbose -p "$(cat "$TEMP_DIR/prompt.txt")" >"$TEMP_DIR/claude-output.txt" 2>&1; then
  log "$RED" "Claude exited with error"
  cat "$TEMP_DIR/claude-output.txt"
  exit 1
fi

# Parse the captured output
while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || continue

  case "$msg_type" in
    "system")
      log "$DIM" "session started"
      ;;
    "assistant")
      # Check for text content (the commit message)
      content_type=$(echo "$line" | jq -r '.message.content[0].type // empty' 2>/dev/null)
      if [[ "$content_type" == "text" ]]; then
        text=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null)
        if [[ -n "$text" ]]; then
          # Save the commit message to temp file
          echo "$text" >"$TEMP_DIR/commit-message.txt"
        fi
      elif [[ "$content_type" == "tool_use" ]]; then
        tool_name=$(echo "$line" | jq -r '.message.content[0].name // empty' 2>/dev/null)
        log "$YELLOW" "tool: $tool_name"
      fi
      ;;
    "result")
      cost=$(echo "$line" | jq -r '.cost_usd // 0' 2>/dev/null)
      log "$GREEN" "done (\$$cost)"
      ;;
    "error")
      error_msg=$(echo "$line" | jq -r '.error.message // .message // "unknown error"' 2>/dev/null)
      log "$RED" "error: $error_msg"
      ;;
    *)
      # Show unhandled message types in debug mode
      [[ -n "${DEBUG:-}" ]] && log "$YELLOW" "UNHANDLED: $msg_type"
      ;;
  esac
done <"$TEMP_DIR/claude-output.txt"

# Read commit message from temp file
if [[ ! -f "$TEMP_DIR/commit-message.txt" ]]; then
  log "$RED" "Failed to generate commit message"
  exit 1
fi

COMMIT_MESSAGE=$(cat "$TEMP_DIR/commit-message.txt")

# --- DETERMINE ACTION (BRANCH OR COMMIT) ---
CREATE_BRANCH=false
TICKET_BRANCH=""

if [[ "$TICKET_SUPPLIED" == "true" ]]; then
  # Check if current branch already contains the ticket ID (case-insensitive)
  shopt -s nocasematch
  if [[ ! "$BRANCH" =~ $TICKET_ID ]]; then
    CREATE_BRANCH=true
    # Extract branch name from already-fetched ticket context
    TICKET_BRANCH=$(sed -n '/=== TICKET ===/,$ p' "$TEMP_DIR/ticket-context.txt" | tail -n +2 | jq -r '.branchName // empty')
    if [[ -z "$TICKET_BRANCH" ]]; then
      log "$RED" "Could not get branch name from ticket for $TICKET_ID"
      exit 1
    fi
  fi
  shopt -u nocasematch
fi

# --- OUTPUT SHELL COMMAND TO STDOUT ---
if [[ "$CREATE_BRANCH" == "true" ]]; then
  cat <<EOF
git-spice branch create '$TICKET_BRANCH' -m "\$(cat <<'COMMIT_MSG'
$COMMIT_MESSAGE
COMMIT_MSG
)"
EOF
else
  cat <<EOF
git commit -m "\$(cat <<'COMMIT_MSG'
$COMMIT_MESSAGE
COMMIT_MSG
)"
EOF
fi
