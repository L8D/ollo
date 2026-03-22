#!/usr/bin/env bash
set -euo pipefail

# ─── Usage ───────────────────────────────────────────────────────────────────
# ollo emit TICKET_ID EVENT_NAME [--origin=SOURCE] [key=value...]
#
# Appends a JSON event line to .ollo/sessions/TICKET_ID.jsonl
# Graceful no-op if TICKET_ID is empty.

TICKET_ID="${1:-}"
if [[ -z "$TICKET_ID" ]]; then
  exit 0
fi
shift

EVENT_NAME="${1:?Usage: ollo emit TICKET_ID EVENT_NAME [--origin=SOURCE] [key=value...]}"
shift

# ─── Parse remaining args ────────────────────────────────────────────────────
ORIGIN=""
KV_PAIRS=()

for arg in "$@"; do
  if [[ "$arg" == --origin=* ]]; then
    ORIGIN="${arg#--origin=}"
  else
    KV_PAIRS+=("$arg")
  fi
done

# ─── Build JSON ──────────────────────────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

JQ_EXPR='{ts: $ts, name: $name}'
JQ_ARGS=(--arg ts "$TS" --arg name "$EVENT_NAME")

if [[ -n "$ORIGIN" ]]; then
  JQ_EXPR="$JQ_EXPR + {origin: \$origin}"
  JQ_ARGS+=(--arg origin "$ORIGIN")
fi

for kv in "${KV_PAIRS[@]}"; do
  key="${kv%%=*}"
  value="${kv#*=}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    JQ_EXPR="$JQ_EXPR + {(\"$key\"): $value}"
  else
    JQ_EXPR="$JQ_EXPR + {(\"$key\"): \$kv_$key}"
    JQ_ARGS+=(--arg "kv_$key" "$value")
  fi
done

# ─── Write event ─────────────────────────────────────────────────────────────
SESSION_DIR=".ollo/sessions"
mkdir -p "$SESSION_DIR"
jq -nc "$JQ_EXPR" "${JQ_ARGS[@]}" >>"$SESSION_DIR/$TICKET_ID.jsonl"
