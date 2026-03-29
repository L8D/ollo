#!/usr/bin/env bash
# Backtest the decomposition plan parser against all existing plans in Kota
# Usage: tools/ollo/tests/test-decomposition-parser.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OLLO_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export OLLO_HOME
OLLO_BIN="$OLLO_HOME/bin/ollo"

REFERENCE_CACHE="$HOME/lab/worktrees/main/cache"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

PASS=0
FAIL=0
SKIP=0
ERRORS=""

# Get all tickets
TICKETS=$(kota tickets list | jq -r '.[].identifier')

for TICKET in $TICKETS; do
  TEST_OUTPUT="$TEMP_DIR/$TICKET"
  mkdir -p "$TEST_OUTPUT"

  # Run the parser in dry-run mode
  if ! OUTPUT=$("$OLLO_BIN" create-subtasks-from-decomposition-plan \
    --from-ticket "$TICKET" --dry-run --output-dir "$TEST_OUTPUT" 2>&1); then
    if echo "$OUTPUT" | grep -q 'no plan documents found'; then
      continue # No plan — not a test candidate
    fi
    if echo "$OUTPUT" | grep -q 'failed to fetch ticket'; then
      continue # Cannot fetch ticket, skip
    fi
    if echo "$OUTPUT" | grep -q 'no subtasks found in plan'; then
      continue # Plan exists but uses a different format — not a test candidate
    fi
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\nFAIL: $TICKET — parser error: $OUTPUT"
    continue
  fi

  # Idempotent no-op (subtasks already created) — skip
  if [[ ! -f "$TEST_OUTPUT/payload.json" ]]; then
    SKIP=$((SKIP + 1))
    echo "SKIP: $TICKET — subtasks already created (idempotent no-op)"
    continue
  fi

  # Check if reference cache exists
  REF_DIR="$REFERENCE_CACHE/$TICKET"
  if [[ ! -d "$REF_DIR" ]]; then
    SKIP=$((SKIP + 1))
    echo "SKIP: $TICKET — no reference cache (parser ran successfully)"
    continue
  fi

  # Compare payload.json (normalize for comparison — sort keys, ignore whitespace differences)
  PLAN_OK=true

  if [[ -f "$REF_DIR/payload.json" ]]; then
    # Compare subtask identifiers and titles (ignore contentPath since output-dir differs)
    REF_SUBTASKS=$(jq -S '[.subtasks[] | {identifier, title}]' "$REF_DIR/payload.json")
    GEN_SUBTASKS=$(jq -S '[.subtasks[] | {identifier, title}]' "$TEST_OUTPUT/payload.json")

    if [[ "$REF_SUBTASKS" != "$GEN_SUBTASKS" ]]; then
      PLAN_OK=false
      ERRORS="${ERRORS}\nFAIL: $TICKET — payload.json subtask mismatch"
      ERRORS="${ERRORS}\n  Expected: $REF_SUBTASKS"
      ERRORS="${ERRORS}\n  Got:      $GEN_SUBTASKS"
    fi
  fi

  # Compare each SUBTASK-XXX.md content
  for REF_FILE in "$REF_DIR"/SUBTASK-*.md; do
    [[ -f "$REF_FILE" ]] || continue
    SUBTASK_NAME=$(basename "$REF_FILE")
    GEN_FILE="$TEST_OUTPUT/$SUBTASK_NAME"

    if [[ ! -f "$GEN_FILE" ]]; then
      PLAN_OK=false
      ERRORS="${ERRORS}\nFAIL: $TICKET/$SUBTASK_NAME — file not generated"
      continue
    fi

    if ! diff -q "$REF_FILE" "$GEN_FILE" >/dev/null 2>&1; then
      PLAN_OK=false
      ERRORS="${ERRORS}\nFAIL: $TICKET/$SUBTASK_NAME — content differs"
      diff -u "$REF_FILE" "$GEN_FILE" | head -20 >>"$TEMP_DIR/diffs.txt" 2>/dev/null || true
    fi
  done

  if $PLAN_OK; then
    PASS=$((PASS + 1))
    echo "PASS: $TICKET"
  else
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "=== Backtest Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP (no reference cache, but parser succeeded)"

if [[ -n "$ERRORS" ]]; then
  echo ""
  echo "=== Failures ==="
  echo -e "$ERRORS"
fi

if [[ -f "$TEMP_DIR/diffs.txt" ]]; then
  echo ""
  echo "=== Diffs (first 20 lines each) ==="
  cat "$TEMP_DIR/diffs.txt"
fi

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
