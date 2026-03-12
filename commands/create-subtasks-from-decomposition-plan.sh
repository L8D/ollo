#!/usr/bin/env bash
# Parse a decomposition plan and create subtasks via ollo create-subtasks
# Usage: ollo create-subtasks-from-decomposition-plan [OPTIONS] [FILE]
#
# Options:
#   --from-ticket TICKET_ID   Fetch latest plan from Kota ticket
#   --output-dir DIR     Write files to DIR instead of cache/{ISSUE_ID}/
#   --dry-run            Parse and write cache files but skip ollo create-subtasks
#
# Input: file path, --from-ticket, or stdin
set -euo pipefail

if [[ -z "${OLLO_HOME:-}" ]]; then
  echo "error: OLLO_HOME is not set. Run via 'ollo' dispatcher or set OLLO_HOME." >&2
  exit 1
fi

DRY_RUN=false
FROM_TICKET=""
OUTPUT_DIR=""
FILE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-ticket)
      FROM_TICKET="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      FILE_PATH="$1"
      shift
      ;;
  esac
done

TEMP_PLAN=""
cleanup() { [[ -n "$TEMP_PLAN" ]] && rm -f "$TEMP_PLAN" || true; }
trap cleanup EXIT

if [[ -n "$FROM_TICKET" ]]; then
  TICKET_JSON=$(kota tickets read "$FROM_TICKET" 2>/dev/null) || {
    echo "error: failed to fetch ticket $FROM_TICKET" >&2
    exit 1
  }

  DOC_ID=$(echo "$TICKET_JSON" | jq -r '
    [.documents[] | select(.title | startswith("PLAN "))]
    | sort_by(.updatedAt) | reverse
    | .[0].id // empty
  ')

  if [[ -z "$DOC_ID" ]]; then
    echo "error: no plan documents found in ticket $FROM_TICKET" >&2
    exit 1
  fi

  TEMP_PLAN=$(mktemp)
  kota documents read "$DOC_ID" | jq -r '.content' >"$TEMP_PLAN"
  PLAN_FILE="$TEMP_PLAN"
elif [[ -n "$FILE_PATH" ]]; then
  if [[ ! -f "$FILE_PATH" ]]; then
    echo "error: file not found: $FILE_PATH" >&2
    exit 1
  fi
  PLAN_FILE="$FILE_PATH"
else
  # stdin
  TEMP_PLAN=$(mktemp)
  cat >"$TEMP_PLAN"
  PLAN_FILE="$TEMP_PLAN"
fi

ISSUE_ID=$(grep -m1 '^# Decomposition Plan for ' "$PLAN_FILE" | awk '{print $NF}')
if [[ -z "$ISSUE_ID" ]]; then
  echo "error: could not extract issue ID from plan header" >&2
  echo "Expected first H1 to match: # Decomposition Plan for TICKET-ID" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="cache/${ISSUE_ID}"
fi
mkdir -p "$OUTPUT_DIR"

MANIFEST="$OUTPUT_DIR/manifest.tsv"
rm -f "$MANIFEST"

awk -v cache_dir="$OUTPUT_DIR" -v manifest="$MANIFEST" '
/^### SUBTASK-[0-9]+:/ {
    match($0, /SUBTASK-[0-9]+/)
    identifier = substr($0, RSTART, RLENGTH)
    title = $0
    sub(/^### +SUBTASK-[0-9]+: */, "", title)
    printf "%s\t%s\n", identifier, title >> manifest
}
/^<subtask-document>[[:space:]]*$/ {
    capturing = 1
    outfile = cache_dir "/" identifier ".md"
    first_line = 1
    next
}
capturing && /^<\/subtask-document>[[:space:]]*$/ {
    capturing = 0
    printf "\n" > outfile
    close(outfile)
    next
}
capturing {
    if (first_line) {
        first_line = 0
    } else {
        printf "\n" > outfile
    }
    printf "%s", $0 > outfile
}
' "$PLAN_FILE"

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: no subtasks found in plan" >&2
  exit 1
fi

SUBTASK_COUNT=$(wc -l <"$MANIFEST" | tr -d ' ')
if [[ "$SUBTASK_COUNT" -eq 0 ]]; then
  echo "error: no subtasks found in plan" >&2
  exit 1
fi

PAYLOAD="$OUTPUT_DIR/payload.json"

SUBTASKS_JSON="[]"
while IFS=$'\t' read -r identifier title; do
  SUBTASKS_JSON=$(echo "$SUBTASKS_JSON" | jq \
    --arg id "$identifier" \
    --arg t "$title" \
    --arg p "$OUTPUT_DIR/$identifier.md" \
    '. + [{identifier: $id, title: $t, contentPath: $p}]')
done <"$MANIFEST"

echo "$SUBTASKS_JSON" | jq --arg issueId "$ISSUE_ID" '{issueId: $issueId, subtasks: .}' >"$PAYLOAD"

rm -f "$MANIFEST"

echo "Parsed $SUBTASK_COUNT subtask(s) for $ISSUE_ID" >&2

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run — files written to $OUTPUT_DIR/" >&2
  jq . "$PAYLOAD"
else
  exec ollo create-subtasks "$PAYLOAD"
fi
