#!/usr/bin/env bash
set -euo pipefail
source "${OLLO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/hook-debug.sh"

# Skip if no ticket ID configured
if [ -z "${KOTA_CURRENT_TICKET_ID:-}" ]; then
  exit 0
fi

# Once-per-session guard: check if description already synced
CURRENT_STATE=$(ollo state "$KOTA_CURRENT_TICKET_ID" 2>/dev/null || echo '{}')
if [ "$(echo "$CURRENT_STATE" | jq -r '.synced // false')" = "true" ]; then
  exit 0
fi

# Skip if description sync has been disabled (e.g. started with description as prompt)
if [ "${OLLO_SYNC_DESCRIPTION_ON_PROMPT_ENABLED:-true}" = "false" ]; then
  exit 0
fi

# Read prompt from stdin
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt')

# ─── Step 3: Clean the prompt ───────────────────────────────────────────────

# Step 3A: Strip skill invocation lines from the top (lines matching ^/[a-zA-Z])
LINES=()
SKIP_SKILLS=true
while IFS= read -r line; do
  if [[ "$SKIP_SKILLS" == "true" && "$line" =~ ^/[a-zA-Z] ]]; then
    continue
  fi
  SKIP_SKILLS=false
  LINES+=("$line")
done <<<"$PROMPT"

CLEANED=$(printf '%s\n' "${LINES[@]+"${LINES[@]}"}")

# Step 3B: Handle the header line (ticket ID + title)
if [ -n "$CLEANED" ]; then
  # Get the first line
  FIRST_LINE=$(echo "$CLEANED" | head -1)
  REST_OF_LINES=$(echo "$CLEANED" | tail -n +2)

  # Check if first line starts with ticket ID
  if [[ "$FIRST_LINE" =~ ^${KOTA_CURRENT_TICKET_ID}[[:space:]](.*)$ ]]; then
    REST_OF_LINE="${BASH_REMATCH[1]}"

    # Get the ticket title
    TITLE=$(kota tickets read "$KOTA_CURRENT_TICKET_ID" 2>/dev/null | jq -r '.title // ""' || true)

    # If the rest matches the title exactly, remove entire line; otherwise keep rest
    if [ "$REST_OF_LINE" == "$TITLE" ]; then
      # Remove the entire first line
      CLEANED="$REST_OF_LINES"
    else
      # Keep the rest of the line
      CLEANED=$(printf '%s\n%s' "$REST_OF_LINE" "$REST_OF_LINES")
    fi
  fi
fi

# Step 3C: Trim leading and trailing whitespace
CLEANED=$(echo "$CLEANED" | sed -e '1{/^[[:space:]]*$/d;}' -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')

# Step 3D: Exit if empty after cleaning
if [ -z "$CLEANED" ] || [ -z "$(echo "$CLEANED" | tr -d '[:space:]')" ]; then
  exit 0
fi

# ─── Step 3E: Read description and skip if prompt content is redundant ──────
CURRENT_DESC=$(kota tickets read "$KOTA_CURRENT_TICKET_ID" 2>/dev/null | jq -r '.description // ""' || true)

# Normalize text for deduplication by stripping all image references.
# This ensures that prompts with rewritten @-prefixed image paths still
# deduplicate against descriptions with bare filenames or URLs.
strip_image_refs() {
  sed -E \
    -e 's#!\[[^]]*\]\([^)]*\)##g' \
    -e 's#[[:space:]]*@[^ ]*\.(png|jpg|jpeg|gif|svg|webp)[[:space:]]*##gi' \
    -e 's#\* *`[^`]*\.(png|jpg|jpeg|gif|svg|webp)`[^*]*##gi' \
    -e 's#https?://[^ ]*\.(png|jpg|jpeg|gif|svg|webp)[^ ]*##gi'
}

if [ -n "$CURRENT_DESC" ]; then
  NORM_DESC=$(printf '%s' "$CURRENT_DESC" | strip_image_refs)
  NORM_CLEANED=$(printf '%s' "$CLEANED" | strip_image_refs)

  # Check (a): cleaned prompt appears verbatim in description (after normalization)
  if printf '%s' "$NORM_DESC" | grep -qF "$NORM_CLEANED"; then
    ollo emit TicketDescriptionUpdated --origin=sync-description
    exit 0
  fi

  # Check (b): cleaned prompt was previously appended as a blockquote
  CLEANED_BQ=""
  while IFS= read -r line; do
    if [ -z "$line" ]; then
      CLEANED_BQ="$CLEANED_BQ
> "
    else
      CLEANED_BQ="$CLEANED_BQ
> $line"
    fi
  done <<<"$CLEANED"
  CLEANED_BQ="${CLEANED_BQ:1}"

  NORM_CLEANED_BQ=$(printf '%s' "$CLEANED_BQ" | strip_image_refs)

  if printf '%s' "$NORM_DESC" | grep -qF "$NORM_CLEANED_BQ"; then
    ollo emit TicketDescriptionUpdated --origin=sync-description
    exit 0
  fi
fi

# ─── Step 4: Update based on current state ──────────────────────────────────
if [ -z "$CURRENT_DESC" ]; then
  # Empty description: set directly
  kota tickets update "$KOTA_CURRENT_TICKET_ID" --description "$CLEANED" >/dev/null 2>&1 || true
else
  # Non-empty: append as blockquote
  # Build blockquoted prompt (prefix each line with "> ")
  BLOCKQUOTED=""
  while IFS= read -r line; do
    if [ -z "$line" ]; then
      BLOCKQUOTED="$BLOCKQUOTED
> "
    else
      BLOCKQUOTED="$BLOCKQUOTED
> $line"
    fi
  done <<<"$CLEANED"

  # Remove leading newline
  BLOCKQUOTED="${BLOCKQUOTED:1}"

  # Combine with existing description
  NEW_DESC="$CURRENT_DESC

---

> **Planning prompt:**
>
$BLOCKQUOTED"

  kota tickets update "$KOTA_CURRENT_TICKET_ID" --description "$NEW_DESC" >/dev/null 2>&1 || true
fi

# ─── Step 6: Record sync event ──────────────────────────────────────────────
ollo emit TicketDescriptionUpdated --origin=sync-description

exit 0
