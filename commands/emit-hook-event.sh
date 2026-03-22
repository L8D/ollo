#!/usr/bin/env bash
set -euo pipefail

# ─── Usage ───────────────────────────────────────────────────────────────────
# ollo emit-hook-event <HOOK_TYPE>
#
# Generic hook event emitter. Reads Claude Code hook JSON from stdin,
# extracts relevant fields, and appends a ClaudeHookFired event.
#
# HOOK_TYPE: SessionStart | Stop | PermissionRequest | PreToolUse | UserPromptSubmit

HOOK_TYPE="${1:?Usage: ollo emit-hook-event <HOOK_TYPE>}"

# Exit silently if no ticket context
if [[ -z "${KOTA_CURRENT_TICKET_ID:-}" ]]; then
  exit 0
fi

# ─── Read stdin ─────────────────────────────────────────────────────────────
INPUT=$(cat)

# ─── Extract common fields ──────────────────────────────────────────────────
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# ─── Build emit args ───────────────────────────────────────────────────────
EMIT_ARGS=(
  "$KOTA_CURRENT_TICKET_ID"
  ClaudeHookFired
  --origin=claude-hook
  "hook=$HOOK_TYPE"
  "sessionId=$SESSION_ID"
  "cwd=$CWD"
)

# ─── Extract hook-type-specific fields ──────────────────────────────────────
case "$HOOK_TYPE" in
  SessionStart)
    SOURCE=$(echo "$INPUT" | jq -r '.source // ""')
    EMIT_ARGS+=("source=$SOURCE")
    ;;
  PreToolUse)
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
    EMIT_ARGS+=("tool=$TOOL_NAME")
    ;;
  UserPromptSubmit)
    PROJECT_KEY="$(echo "$CWD" | tr '/' '-' | tr '.' '-')"
    TRANSCRIPT_PATH="$HOME/.claude/projects/${PROJECT_KEY}/${SESSION_ID}.jsonl"
    EMIT_ARGS+=("transcriptPath=$TRANSCRIPT_PATH")
    ;;
esac

# ─── Emit ───────────────────────────────────────────────────────────────────
ollo emit "${EMIT_ARGS[@]}"
