#!/usr/bin/env bash
set -euo pipefail

# Skip if no ticket ID configured
if [ -z "${KOTA_CURRENT_TICKET_ID:-}" ]; then
  exit 0
fi

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
CWD=$(echo "$INPUT" | jq -r '.cwd')

# Derive transcript path (same logic as get-plan-filepath-by-session-id)
PROJECT_KEY=$(echo "$CWD" | sed 's/\//-/g' | sed 's/^-//')
TRANSCRIPT="$HOME/.claude/projects/-${PROJECT_KEY}/${SESSION_ID}.jsonl"

if [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

# Find plan filename from transcript (5 methods, in order of reliability)
PLAN_FILENAME=""

# Method 1: file-history-snapshot trackedFileBackups keys
if [ -z "$PLAN_FILENAME" ]; then
  PLAN_FILENAME=$(jq -r 'select(.type == "file-history-snapshot") | .snapshot.trackedFileBackups // {} | keys[] | select(contains(".claude/plans/"))' "$TRANSCRIPT" 2>/dev/null | head -1 | xargs -I{} basename {} 2>/dev/null || true)
fi

# Method 2: toolUseResult.filePath
if [ -z "$PLAN_FILENAME" ]; then
  PLAN_FILENAME=$(jq -r 'select(.toolUseResult.filePath) | .toolUseResult.filePath | select(contains(".claude/plans/"))' "$TRANSCRIPT" 2>/dev/null | head -1 | xargs -I{} basename {} 2>/dev/null || true)
fi

# Method 3: tool_result content in message.content array
if [ -z "$PLAN_FILENAME" ]; then
  PLAN_FILENAME=$(jq -r '.message.content[]? | select(.type == "tool_result") | .content | select(type == "string" and contains(".claude/plans/"))' "$TRANSCRIPT" 2>/dev/null | grep -oE '\.claude/plans/[^"[:space:]]+\.md' | head -1 | xargs -I{} basename {} 2>/dev/null || true)
fi

# Method 4: string message.content with capture
if [ -z "$PLAN_FILENAME" ]; then
  PLAN_FILENAME=$(jq -r 'select(.message.content | type == "string") | .message.content | capture("\\.claude/plans/(?<name>[^\"\\n]+\\.md)") | .name' "$TRANSCRIPT" 2>/dev/null | head -1 || true)
fi

# Method 5: brute force grep
if [ -z "$PLAN_FILENAME" ]; then
  PLAN_FILENAME=$(grep -oE '\.claude/plans/[a-z]+-[a-z]+-[a-z]+\.md' "$TRANSCRIPT" 2>/dev/null | head -1 | xargs -I{} basename {} 2>/dev/null || true)
fi

if [ -z "$PLAN_FILENAME" ]; then
  exit 0
fi

PLAN_FILE="$HOME/.claude/plans/$PLAN_FILENAME"
if [ ! -f "$PLAN_FILE" ]; then
  exit 0
fi

# Backup to Kota
kota documents create \
  --ticket "$KOTA_CURRENT_TICKET_ID" \
  --title "PLAN $SESSION_ID: $(head -1 "$PLAN_FILE")" \
  --content "$(cat "$PLAN_FILE")" \
  >/dev/null 2>&1 || true

exit 0
