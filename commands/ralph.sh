#!/usr/bin/env bash
# ralph-stream - Automated Claude task runner with streaming progress
set -euo pipefail

if [[ -z "${OLLO_HOME:-}" ]]; then
  echo "error: OLLO_HOME is not set. Run via 'ollo' dispatcher or set OLLO_HOME." >&2
  exit 1
fi

PROJECT_DIR="$(pwd)"
SESSION_ID_FILE="$PROJECT_DIR/.claude/ralph-session-id"

# Generate temp settings file with resolved hook path
RALPH_SETTINGS=$(mktemp)
sed "s|__OLLO_PERMISSION_PROMPT__|$OLLO_HOME/lib/permission-prompt.sh|g" \
  "$OLLO_HOME/lib/settings.json" >"$RALPH_SETTINGS"

DIM='\033[2m'
RESET='\033[0m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'

# Exit notification state
EXIT_STATUS="failure"
EXIT_MESSAGE=""

cleanup_temp_settings() {
  rm -f "$RALPH_SETTINGS"
}

send_slack_notification() {
  crier

  [[ -z "${SLACK_BEARER_TOKEN:-}" ]] && return

  local emoji
  if [[ "$EXIT_STATUS" == "success" ]]; then
    emoji="✅"
  else
    emoji="❌"
  fi

  local message="${emoji} Ralph ${EXIT_STATUS}"
  [[ -n "$EXIT_MESSAGE" ]] && message="$message: $EXIT_MESSAGE"

  curl -s -X POST "https://slack.com/api/reminders.add" \
    -H "Authorization: Bearer $SLACK_BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"$message\", \"time\": \"in 1 second\"}" >/dev/null 2>&1 || true
}

PIPELINE_PID=""
SOFT_INTERRUPTED=false

handle_soft_interrupt() {
  if [[ -n "$PIPELINE_PID" ]]; then
    log "$YELLOW" "Soft interrupt - stopping Claude..."
    pkill -P "$PIPELINE_PID" 2>/dev/null || true
    kill "$PIPELINE_PID" 2>/dev/null || true
  fi
  SOFT_INTERRUPTED=true
}

handle_interrupt() {
  EXIT_STATUS="interrupted"
  EXIT_MESSAGE="Interrupted by user"
  trap - INT TERM EXIT
  if [[ -n "$PIPELINE_PID" ]]; then
    pkill -P "$PIPELINE_PID" 2>/dev/null || true
    kill "$PIPELINE_PID" 2>/dev/null || true
    wait "$PIPELINE_PID" 2>/dev/null || true
  fi
  send_slack_notification
  exit 130
}

cleanup_all() {
  cleanup_temp_settings
  send_slack_notification
}
trap cleanup_all EXIT
trap handle_interrupt INT TERM
trap handle_soft_interrupt QUIT

log() {
  local color="$1" message="$2"
  printf "${DIM}[%s]${RESET} ${color}%s${RESET}\n" "$(date +%H:%M:%S)" "$message"
}

log_multiline() {
  local color="$1"
  shift
  local timestamp
  timestamp=$(date +%H:%M:%S)
  printf "${DIM}[%s]${RESET} ${color}" "$timestamp"
  printf "%s" "$@"
  printf "${RESET}\n"
}

format_tool_call() {
  local tool_name="$1"
  local tool_input="$2"

  case "$tool_name" in
    "Bash")
      local command=$(echo "$tool_input" | jq -r '.command // empty')
      local description=$(echo "$tool_input" | jq -r '.description // empty')
      local timeout=$(echo "$tool_input" | jq -r '.timeout // empty')
      local background=$(echo "$tool_input" | jq -r '.run_in_background // empty')
      printf "Bash\n"
      printf "  command: %s\n" "$command"
      [[ -n "$description" ]] && printf "  description: %s\n" "$description"
      [[ -n "$timeout" && "$timeout" != "null" ]] && printf "  timeout: %s\n" "$timeout"
      [[ "$background" == "true" ]] && printf "  run_in_background: true\n"
      ;;
    "Read")
      local file_path=$(echo "$tool_input" | jq -r '.file_path // empty')
      local offset=$(echo "$tool_input" | jq -r '.offset // empty')
      local limit=$(echo "$tool_input" | jq -r '.limit // empty')
      if [[ -n "$offset" && "$offset" != "null" ]] || [[ -n "$limit" && "$limit" != "null" ]]; then
        printf "Read(%s" "$file_path"
        [[ -n "$offset" && "$offset" != "null" ]] && printf ", offset=%s" "$offset"
        [[ -n "$limit" && "$limit" != "null" ]] && printf ", limit=%s" "$limit"
        printf ")\n"
      else
        printf "Read(%s)\n" "$file_path"
      fi
      ;;
    "Write")
      local file_path=$(echo "$tool_input" | jq -r '.file_path // empty')
      local content_len=$(echo "$tool_input" | jq -r '.content | length')
      printf "Write(%s) [%s chars]\n" "$file_path" "$content_len"
      ;;
    "Edit")
      local file_path=$(echo "$tool_input" | jq -r '.file_path // empty')
      local old_string=$(echo "$tool_input" | jq -r '.old_string // empty')
      local new_string=$(echo "$tool_input" | jq -r '.new_string // empty')
      local replace_all=$(echo "$tool_input" | jq -r '.replace_all // false')
      printf "Edit(%s)\n" "$file_path"
      printf "  old: %s\n" "$(echo "$old_string" | head -c 80)$([ ${#old_string} -gt 80 ] && echo '...')"
      printf "  new: %s\n" "$(echo "$new_string" | head -c 80)$([ ${#new_string} -gt 80 ] && echo '...')"
      [[ "$replace_all" == "true" ]] && printf "  replace_all: true\n"
      ;;
    "TodoWrite")
      local todos=$(echo "$tool_input" | jq -r '.todos // []')
      local count=$(echo "$todos" | jq 'length')
      printf "TodoWrite [%s items]\n" "$count"
      echo "$todos" | jq -r '.[] | "  [\({"completed":"x","in_progress":"-","pending":" "}[.status] // .status)] \(.content)"'
      ;;
    "Glob")
      local pattern=$(echo "$tool_input" | jq -r '.pattern // empty')
      local path=$(echo "$tool_input" | jq -r '.path // empty')
      if [[ -n "$path" && "$path" != "null" ]]; then
        printf "Glob(%s, path=%s)\n" "$pattern" "$path"
      else
        printf "Glob(%s)\n" "$pattern"
      fi
      ;;
    "Grep")
      local pattern=$(echo "$tool_input" | jq -r '.pattern // empty')
      local path=$(echo "$tool_input" | jq -r '.path // empty')
      local glob=$(echo "$tool_input" | jq -r '.glob // empty')
      printf "Grep(%s" "$pattern"
      [[ -n "$path" && "$path" != "null" ]] && printf ", path=%s" "$path"
      [[ -n "$glob" && "$glob" != "null" ]] && printf ", glob=%s" "$glob"
      printf ")\n"
      ;;
    "Task")
      local description=$(echo "$tool_input" | jq -r '.description // empty')
      local subagent=$(echo "$tool_input" | jq -r '.subagent_type // empty')
      printf "Task(%s, %s)\n" "$subagent" "$description"
      ;;
    "WebFetch")
      local url=$(echo "$tool_input" | jq -r '.url // empty')
      printf "WebFetch(%s)\n" "$url"
      ;;
    "WebSearch")
      local query=$(echo "$tool_input" | jq -r '.query // empty')
      printf "WebSearch(%s)\n" "$query"
      ;;
    "AskUserQuestion")
      local questions=$(echo "$tool_input" | jq -r '.questions // []')
      local count=$(echo "$questions" | jq 'length')
      printf "AskUserQuestion [%s questions]\n" "$count"
      echo "$questions" | jq -r '.[].question' | while read -r q; do
        printf "  %s\n" "$q"
      done
      ;;
    "Skill")
      local skill=$(echo "$tool_input" | jq -r '.skill // empty')
      local args=$(echo "$tool_input" | jq -r '.args // empty')
      if [[ -n "$args" && "$args" != "null" ]]; then
        printf "Skill(/%s %s)\n" "$skill" "$args"
      else
        printf "Skill(/%s)\n" "$skill"
      fi
      ;;
    mcp__serena__*)
      local short_name="${tool_name#mcp__serena__}"
      printf "serena.%s\n" "$short_name"
      echo "$tool_input" | jq -r 'to_entries | .[] | "  \(.key): \(.value | if type == "string" then . else tostring end | .[0:100])"'
      ;;
    *)
      # Fallback: show tool name with formatted JSON input
      printf "%s\n" "$tool_name"
      echo "$tool_input" | jq -r 'to_entries | .[] | "  \(.key): \(.value | if type == "string" then .[0:100] else tostring end)"'
      ;;
  esac
}

parse_streaming_json() {
  local _img_ids=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Debug: show raw line if DEBUG is set
    [[ -n "${DEBUG:-}" ]] && echo "RAW: $line" >&2

    local msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || continue

    case "$msg_type" in
      "system")
        local session_id
        session_id=$(echo "$line" | jq -r '.session_id // empty')
        log "$DIM" "session: $session_id"
        if [[ -n "$session_id" ]]; then
          printf '%s' "$session_id" >"$SESSION_ID_FILE"
        fi
        ;;
      "user")
        # Tool results come back as user messages
        local content=$(echo "$line" | jq -c '.message.content // []')
        echo "$content" | jq -c '.[]' | while read -r block; do
          local block_type=$(echo "$block" | jq -r '.type // empty')
          if [[ "$block_type" == "tool_result" ]]; then
            local is_error=$(echo "$block" | jq -r '.is_error // false')
            local result=$(echo "$block" | jq -r '.content // "" | if type == "string" then . else tostring end')
            local _tid
            _tid=$(echo "$block" | jq -r '.tool_use_id // empty')
            if [[ -n "$_tid" && "$_img_ids" == *"|${_tid}"* ]]; then
              log "$DIM" "← (image data omitted)"
              continue
            fi
            if [[ "$is_error" == "true" ]]; then
              log "$RED" "← ERROR: $result"
            else
              log "$DIM" "← $result"
            fi
          fi
        done
        ;;
      "assistant")
        local content_type=$(echo "$line" | jq -r '.message.content[0].type // empty')
        case "$content_type" in
          "tool_use")
            local tool_name=$(echo "$line" | jq -r '.message.content[0].name // empty')
            local tool_input=$(echo "$line" | jq -c '.message.content[0].input // {}')
            if [[ "$tool_name" == "Read" ]]; then
              local _fp
              _fp=$(echo "$tool_input" | jq -r '.file_path // empty')
              case "${_fp##*.}" in
                png | PNG | jpg | JPG | jpeg | JPEG | gif | GIF | webp | WEBP)
                  local _id
                  _id=$(echo "$line" | jq -r '.message.content[0].id // empty')
                  [[ -n "$_id" ]] && _img_ids="${_img_ids}|${_id}"
                  ;;
              esac
            fi
            local formatted
            formatted=$(format_tool_call "$tool_name" "$tool_input")
            log_multiline "$CYAN" "$formatted"
            ;;
          "text")
            local text=$(echo "$line" | jq -r '.message.content[0].text // empty')
            if [[ -n "$text" ]]; then
              log "$DIM" "$text"
            fi
            ;;
        esac
        ;;
      "result")
        local subtype=$(echo "$line" | jq -r '.subtype // empty')
        local cost=$(echo "$line" | jq -r '.cost_usd // 0')
        local turns=$(echo "$line" | jq -r '.num_turns // 0')
        log "$GREEN" "RESULT: $subtype - $turns turns, \$$cost"
        ;;
      "error")
        local error_msg=$(echo "$line" | jq -r '.error.message // .message // "unknown error"')
        log "$RED" "ERROR: $error_msg"
        ;;
      *)
        # Show unhandled message types in debug mode
        [[ -n "${DEBUG:-}" ]] && log "$YELLOW" "UNHANDLED: $msg_type"
        ;;
    esac
  done
}

main() {
  local issue_id=""
  local continue_mode=false
  local first_iteration=true

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --continue | -c)
        continue_mode=true
        shift
        ;;
      *)
        issue_id="$1"
        shift
        ;;
    esac
  done

  # Infer ticket ID from branch name if not provided
  if [[ -z "$issue_id" ]]; then
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    local prefix="${KOTA_DEFAULT_PREFIX:-snwlly}"
    local prefix_lower=$(echo "$prefix" | tr '[:upper:]' '[:lower:]')
    issue_id=$(echo "$branch" | grep -oiE "${prefix_lower}-[0-9]+" | tr '[:lower:]' '[:upper:]' | head -1)
    if [[ -z "$issue_id" ]]; then
      echo "Error: No ticket ID provided and could not infer from branch '$branch'" >&2
      exit 1
    fi
  fi

  log "$CYAN" "Ralph Stream starting..."
  [[ "$continue_mode" == "true" ]] && log "$CYAN" "Continue mode enabled for first iteration"

  # Count total subtasks for progress tracking
  local total_subtasks
  total_subtasks=$(kota tickets read "$issue_id" | jq -r '.description' | grep -cE '^\s*- \[[ x]\] SUBTASK-[0-9]{3}:' || echo "0")
  local subtask_counter=0

  while true; do
    # Get next task before starting Claude
    local task_json
    task_json=$(ollo next-subtask $issue_id 2>/dev/null) || {
      log "$RED" "Failed to get next task"
      EXIT_MESSAGE="Failed to get next task"
      exit 1
    }

    # Check if all complete
    if [[ "$(echo "$task_json" | jq -r '.all_complete // false')" == "true" ]]; then
      log "$GREEN" "All tasks complete!"
      coop clear-active-subtask "$issue_id"
      EXIT_STATUS="success"
      EXIT_MESSAGE="All tasks complete"
      break
    fi

    local subtask_id=$(echo "$task_json" | jq -r '.subtask_id')
    local issue_id_from_task=$(echo "$task_json" | jq -r '.issue_id')
    local subtask_title=$(echo "$task_json" | jq -r '.subtask_title // ""')
    local session_name="${issue_id_from_task}, ${subtask_id}: ${subtask_title}"

    subtask_counter=$((subtask_counter + 1))
    coop set-active-subtask "$issue_id" "(${subtask_counter}/${total_subtasks}) ${subtask_id}"

    log "$CYAN" "=== Starting $subtask_id ($issue_id_from_task) ==="

    # Build composite prompt from template + task metadata + document content
    local task_meta doc_content prompt_template prompt
    task_meta=$(echo "$task_json" | jq 'del(.document.content)')
    doc_content=$(echo "$task_json" | jq -r '.document.content // empty')
    prompt_template=$(<"$OLLO_HOME/lib/work-subtask-prompt.md")

    prompt="${prompt_template}

<task-context>
${task_meta}
</task-context>

<subtask-document>
${doc_content}
</subtask-document>"

    [[ -n "${DEBUG:-}" ]] && echo "PROMPT:" >&2 && echo "$prompt" >&2

    # Run Claude with streaming JSON in background so SIGINT can interrupt `wait`
    set +e
    if [[ "$first_iteration" == "true" && "$continue_mode" == "true" ]]; then
      if [[ ! -f "$SESSION_ID_FILE" ]]; then
        log "$RED" "Cannot continue: no session ID file found at $SESSION_ID_FILE"
        log "$RED" "Run ralph without --continue first to establish a session"
        EXIT_MESSAGE="No session ID file for --continue"
        exit 1
      fi
      local resume_session_id
      resume_session_id=$(<"$SESSION_ID_FILE")
      if [[ -z "$resume_session_id" ]]; then
        log "$RED" "Cannot continue: session ID file is empty"
        EXIT_MESSAGE="Empty session ID file for --continue"
        exit 1
      fi
      log "$CYAN" "Using --resume $resume_session_id for first iteration"
      (claude --settings "$RALPH_SETTINGS" --permission-mode acceptEdits --output-format stream-json --verbose --name "$session_name" --resume "$resume_session_id" -p "${RALPH_CONTINUE_MSG:-continue}" 2>&1 | parse_streaming_json) &
    else
      (claude --settings "$RALPH_SETTINGS" --permission-mode acceptEdits --output-format stream-json --verbose --name "$session_name" -p "$prompt" 2>&1 | parse_streaming_json) &
    fi
    PIPELINE_PID=$!
    wait $PIPELINE_PID 2>/dev/null
    local claude_exit=$?
    PIPELINE_PID=""
    first_iteration=false
    set -e

    # Handle soft interrupt (Ctrl+\)
    if [[ "$SOFT_INTERRUPTED" == "true" ]]; then
      SOFT_INTERRUPTED=false

      # Prompt for correction message
      log "$YELLOW" "Enter correction message (then press Enter):"
      local user_message
      read -r user_message </dev/tty

      if [[ -z "$user_message" ]]; then
        log "$YELLOW" "Empty message, using 'continue'"
        user_message="continue"
      fi

      # Read saved session ID
      local soft_resume_session_id
      soft_resume_session_id=$(<"$SESSION_ID_FILE")
      if [[ -z "$soft_resume_session_id" ]]; then
        log "$RED" "No session ID available for resume"
        EXIT_MESSAGE="Soft interrupt failed: no session ID"
        exit 1
      fi

      # Loop to handle repeated soft interrupts on resumed sessions
      while true; do
        log "$CYAN" "Resuming session with: $user_message"

        # Run Claude with --resume and user's message
        set +e
        (claude --settings "$RALPH_SETTINGS" \
          --permission-mode acceptEdits \
          --output-format stream-json \
          --verbose \
          --name "$session_name" \
          --resume "$soft_resume_session_id" \
          -p "$user_message" 2>&1 | parse_streaming_json) &
        PIPELINE_PID=$!
        wait $PIPELINE_PID 2>/dev/null
        claude_exit=$?
        PIPELINE_PID=""
        set -e

        # If soft-interrupted again, prompt again and loop
        if [[ "$SOFT_INTERRUPTED" == "true" ]]; then
          SOFT_INTERRUPTED=false
          log "$YELLOW" "Enter correction message (then press Enter):"
          read -r user_message </dev/tty
          if [[ -z "$user_message" ]]; then
            log "$YELLOW" "Empty message, using 'continue'"
            user_message="continue"
          fi
          # Re-read session ID (may have changed)
          soft_resume_session_id=$(<"$SESSION_ID_FILE")
          if [[ -z "$soft_resume_session_id" ]]; then
            log "$RED" "No session ID available for resume"
            EXIT_MESSAGE="Soft interrupt failed: no session ID"
            exit 1
          fi
          continue # loop back to resume again
        fi

        # No interrupt — break out to the outer loop's task-completion check
        break
      done

      # After soft-interrupt resume chain, loop back to check task status
      continue
    fi

    if [[ $claude_exit -ne 0 ]]; then
      log "$YELLOW" "Claude exited with code $claude_exit"
    fi

    # After Claude exits, check if we're still on the same task
    local post_task_json
    post_task_json=$(ollo next-subtask $issue_id 2>/dev/null) || {
      log "$RED" "Failed to check task status"
      coop clear-active-subtask "$issue_id"
      EXIT_MESSAGE="Failed to check task status"
      exit 1
    }

    # Check if all complete now
    if [[ "$(echo "$post_task_json" | jq -r '.all_complete // false')" == "true" ]]; then
      log "$GREEN" "All tasks complete!"
      coop clear-active-subtask "$issue_id"
      EXIT_STATUS="success"
      EXIT_MESSAGE="All tasks complete"
      break
    fi

    local post_subtask_id=$(echo "$post_task_json" | jq -r '.subtask_id')

    # If still on same task, Claude failed to complete it
    if [[ "$post_subtask_id" == "$subtask_id" ]]; then
      log "$RED" "Still on $subtask_id - Claude failed to complete task, exiting"
      coop clear-active-subtask "$issue_id"
      EXIT_MESSAGE="Claude failed to complete task $subtask_id"
      exit 1
    fi

    log "$GREEN" "Task $subtask_id completed, moving to next..."
  done

  log "$GREEN" "Ralph Stream finished"
}

main "$@"
