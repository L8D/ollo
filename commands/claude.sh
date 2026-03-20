#!/usr/bin/env bash
set -euo pipefail

# ─── Arg parsing ────────────────────────────────────────────────────────────
# Usage: ollo claude <TICKET_ID> [--reset] [-- claude args...]
# Everything before '--' is parsed by ollo; everything after '--' forwarded to claudish.

TICKET_ID=""
RESET=false
OLLO_ARGS=()
CLAUDE_ARGS=()
PAST_SEPARATOR=false

for arg in "$@"; do
  if [[ "$PAST_SEPARATOR" == "true" ]]; then
    CLAUDE_ARGS+=("$arg")
  elif [[ "$arg" == "--" ]]; then
    PAST_SEPARATOR=true
  elif [[ "$arg" == "--reset" ]]; then
    RESET=true
  elif [[ -z "$TICKET_ID" ]]; then
    TICKET_ID="$arg"
  else
    OLLO_ARGS+=("$arg")
  fi
done

if [[ -z "$TICKET_ID" ]]; then
  echo "Usage: ollo claude <TICKET_ID> [--reset] [-- claude args...]" >&2
  exit 1
fi

# ─── Environment ────────────────────────────────────────────────────────────
export KOTA_CURRENT_TICKET_ID="$TICKET_ID"

# ─── State management ───────────────────────────────────────────────────────
STATE_DIR=".claude/ollo-sessions"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$TICKET_ID"

if [[ "$RESET" == "true" ]]; then
  CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
  NEXT=$((CURRENT + 1))
  printf '%s' "$NEXT" >"$STATE_FILE"
  rm -f "$STATE_DIR/$TICKET_ID.synced"
  echo "Session reset for $TICKET_ID (generation $NEXT — next invocation will start a new session)" >&2
  exit 0
fi

GENERATION=$(cat "$STATE_FILE" 2>/dev/null || echo "0")

# ─── Deterministic session ID ────────────────────────────────────────────────
PROJECT_KEY="$(pwd | tr '/' '-' | tr '.' '-')"
HEX=$(printf '%s:%s:%s' "$TICKET_ID" "$PROJECT_KEY" "$GENERATION" | shasum -a 256 | cut -c1-32)
SESSION_ID="${HEX:0:8}-${HEX:8:4}-${HEX:12:4}-${HEX:16:4}-${HEX:20:12}"

# ─── Resume or create ────────────────────────────────────────────────────────
TRANSCRIPT_FILE="$HOME/.claude/projects/${PROJECT_KEY}/${SESSION_ID}.jsonl"

if [[ -f "$TRANSCRIPT_FILE" ]]; then
  echo "Session $SESSION_ID exists — resuming. (${TICKET_ID} gen ${GENERATION})" >&2
  exec claudish --interactive --resume "$SESSION_ID" "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"
else
  echo "Session $SESSION_ID not found — creating. (${TICKET_ID} gen ${GENERATION})" >&2
  exec claudish --interactive --session-id "$SESSION_ID" "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"
fi
