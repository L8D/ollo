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

# Extract clarifications and user follow-ups from transcript
{
  # Step 1: Extract AskUserQuestion Q&A pairs
  AQ_CONTENT=$(jq -r '
    select(.type == "assistant") |
    {
      uuid: .uuid,
      content: .message.content // []
    } |
    .content as $content |
    (
      ($content | to_entries | map(select(.value.type == "tool_use" and .value.name == "AskUserQuestion"))) as $tool_uses |
      ($content | map(select(.type == "tool_result"))) as $results |
      $tool_uses[] as $tool_use_entry |
      ($results[] | select(.tool_use_id == $tool_use_entry.value.id)) as $result |
      {
        uuid: .uuid,
        type: "question",
        data: {
          questions: $tool_use_entry.value.input.questions,
          answer: $result.content
        }
      }
    )
  ' "$TRANSCRIPT" 2>/dev/null)

  # Step 2: Extract user follow-up messages (all except first)
  USER_CONTENT=$(jq -r '
    select(.type == "user") |
    {
      uuid: .uuid,
      type: "user_message",
      message: .message.content
    }
  ' "$TRANSCRIPT" 2>/dev/null | tail -n +2)

  # Step 3: Format clarifications as blockquoted section
  CLARIFICATIONS_FILE=$(mktemp)
  {
    if [ -n "$AQ_CONTENT" ] || [ -n "$USER_CONTENT" ]; then
      echo ""
      echo "---"
      echo ""
      echo "> ## Planning Clarifications"
      echo ">"

      # Process AskUserQuestion entries
      if [ -n "$AQ_CONTENT" ]; then
        while IFS= read -r line; do
          if [ -z "$line" ]; then
            continue
          fi

          UUID=$(echo "$line" | jq -r '.uuid')
          QUESTIONS=$(echo "$line" | jq -r '.data.questions // []')
          ANSWER=$(echo "$line" | jq -r '.data.answer // ""')

          echo "> <!-- uuid:$UUID -->"

          # Extract and format all questions and options
          QUESTION_TEXT=$(echo "$QUESTIONS" | jq -r '.[] | .question // ""' | head -1)
          if [ -n "$QUESTION_TEXT" ]; then
            echo "> **Q:** $QUESTION_TEXT"

            # Format options
            echo "$QUESTIONS" | jq -r '.[] | .options[]? | "- \(.label): \(.description)"' | while IFS= read -r opt; do
              echo "> $opt"
            done
          fi

          if [ -n "$ANSWER" ]; then
            echo ">"
            echo "> **A:** $ANSWER"
          fi

          echo ">"
        done <<<"$AQ_CONTENT"
      fi

      # Process user follow-up messages
      if [ -n "$USER_CONTENT" ]; then
        while IFS= read -r line; do
          if [ -z "$line" ]; then
            continue
          fi

          UUID=$(echo "$line" | jq -r '.uuid')
          MESSAGE=$(echo "$line" | jq -r '.message // ""')

          echo "> <!-- uuid:$UUID -->"

          # Format multi-line user messages with blockquote prefix
          echo "$MESSAGE" | while IFS= read -r msg_line; do
            if [ -z "$msg_line" ]; then
              echo ">"
            else
              echo "> **User:** $msg_line"
            fi
          done

          echo ">"
        done <<<"$USER_CONTENT"
      fi
    fi
  } >"$CLARIFICATIONS_FILE"

  # Step 4: Append only new items to ticket description (UUID-based deduplication)
  if [ -s "$CLARIFICATIONS_FILE" ]; then
    CURRENT_DESC=$(kota tickets read "$KOTA_CURRENT_TICKET_ID" 2>/dev/null | jq -r '.description // ""' || true)

    if [ -n "$CURRENT_DESC" ]; then
      # Filter out items whose UUIDs are already in the description
      FILTERED_CLARIFICATIONS=""
      while IFS= read -r line; do
        if [[ "$line" =~ uuid:([a-zA-Z0-9-]+) ]]; then
          UUID_TO_CHECK="${BASH_REMATCH[1]}"
          if ! echo "$CURRENT_DESC" | grep -q "uuid:$UUID_TO_CHECK"; then
            FILTERED_CLARIFICATIONS+="$line"$'\n'
          fi
        else
          FILTERED_CLARIFICATIONS+="$line"$'\n'
        fi
      done <"$CLARIFICATIONS_FILE"

      if [ -n "$FILTERED_CLARIFICATIONS" ]; then
        COMBINED_DESC="${CURRENT_DESC}${FILTERED_CLARIFICATIONS}"
        kota tickets update "$KOTA_CURRENT_TICKET_ID" --description "$COMBINED_DESC" >/dev/null 2>&1 || true
      fi
    else
      # No existing description, just append the clarifications
      kota tickets update "$KOTA_CURRENT_TICKET_ID" --description "$(cat "$CLARIFICATIONS_FILE")" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$CLARIFICATIONS_FILE"
} || true

exit 0
