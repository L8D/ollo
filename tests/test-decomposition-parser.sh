#!/usr/bin/env bash
# Backtest the decomposition plan parser against all existing plans in Kota
# Usage: tools/ollo/tests/test-decomposition-parser.sh
set -euo pipefail

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
  # Get documents for this ticket
  DOCS=$(kota documents list --ticket "$TICKET" 2>/dev/null | jq -r '.[].id' || true)

  for DOC_ID in $DOCS; do
    CONTENT=$(kota documents read "$DOC_ID" 2>/dev/null | jq -r '.content // ""' || true)

    # Check if this is a decomposition plan
    if ! echo "$CONTENT" | grep -q '<subtask-document>'; then
      continue
    fi
    if ! echo "$CONTENT" | grep -q '^# Decomposition Plan for '; then
      continue
    fi

    # This is a decomposition plan — test it
    PLAN_ISSUE=$(echo "$CONTENT" | grep -m1 '^# Decomposition Plan for ' | awk '{print $NF}')
    TEST_OUTPUT="$TEMP_DIR/$PLAN_ISSUE"
    mkdir -p "$TEST_OUTPUT"

    # Write plan to temp file
    PLAN_FILE="$TEMP_DIR/${PLAN_ISSUE}.md"
    echo "$CONTENT" >"$PLAN_FILE"

    # Run the parser in dry-run mode
    if ! ollo create-subtasks-from-decomposition-plan --dry-run --output-dir "$TEST_OUTPUT" "$PLAN_FILE" >/dev/null 2>&1; then
      FAIL=$((FAIL + 1))
      ERRORS="${ERRORS}\nFAIL: $DOC_ID ($PLAN_ISSUE) — parser crashed"
      continue
    fi

    # Check if reference cache exists
    REF_DIR="$REFERENCE_CACHE/$PLAN_ISSUE"
    if [[ ! -d "$REF_DIR" ]]; then
      SKIP=$((SKIP + 1))
      echo "SKIP: $PLAN_ISSUE — no reference cache (parser ran successfully)"
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
        ERRORS="${ERRORS}\nFAIL: $PLAN_ISSUE — payload.json subtask mismatch"
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
        ERRORS="${ERRORS}\nFAIL: $PLAN_ISSUE/$SUBTASK_NAME — file not generated"
        continue
      fi

      if ! diff -q "$REF_FILE" "$GEN_FILE" >/dev/null 2>&1; then
        PLAN_OK=false
        ERRORS="${ERRORS}\nFAIL: $PLAN_ISSUE/$SUBTASK_NAME — content differs"
        diff -u "$REF_FILE" "$GEN_FILE" | head -20 >>"$TEMP_DIR/diffs.txt" 2>/dev/null || true
      fi
    done

    if $PLAN_OK; then
      PASS=$((PASS + 1))
      echo "PASS: $PLAN_ISSUE"
    else
      FAIL=$((FAIL + 1))
    fi
  done
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
