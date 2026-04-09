#!/usr/bin/env bash
# Permission Prompt Hook (ralph + interactive)
# Checks if tool use is allowed/denied in settings.local.json, prompts via osascript if not

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLO_HOME="${OLLO_HOME:-"$(cd "$SCRIPT_DIR/.." && pwd)"}"
source "$OLLO_HOME/lib/hook-debug.sh"

# Detect mode: ralph exports OLLO_MODE=ralph, interactive opts in via OLLO_PERMISSION_PROMPT_ENABLED=true
OLLO_MODE="${OLLO_MODE:-interactive}"
if [[ "$OLLO_MODE" != "ralph" && "${OLLO_PERMISSION_PROMPT_ENABLED:-}" != "true" ]]; then
  exit 0
fi

# SETTINGS_FILE is set below after reading stdin (needs cwd from hook input JSON)

# Path to the bash-split binary (real bash AST parser).
# Override via BASH_SPLIT env var; default is relative to OLLO_HOME.
BASH_SPLIT="${BASH_SPLIT:-"$OLLO_HOME/lib/bash-split/dist/bash-split"}"

# Read JSON input from stdin
input=$(cat)

# Resolve project settings file: prefer CLAUDE_PROJECT_DIR env var, fall back to cwd from hook input JSON
hook_cwd=$(echo "$input" | jq -r '.cwd // ""')
SETTINGS_FILE="${CLAUDE_PROJECT_DIR:-${hook_cwd:-.}}/.claude/settings.local.json"
[[ -L "$SETTINGS_FILE" ]] && SETTINGS_FILE="$(readlink -f "$SETTINGS_FILE")"
[[ -n "${RALPH_DEBUG:-}" ]] && echo "DEBUG: OLLO_MODE=$OLLO_MODE SETTINGS_FILE=$SETTINGS_FILE exists=$(test -f "$SETTINGS_FILE" && echo yes || echo no)" >&2

# Extract tool information
tool_name=$(echo "$input" | jq -r '.tool_name')
tool_input=$(echo "$input" | jq -c '.tool_input // {}')

# Extract a permission key from a single (non-compound) command string.
# Returns format: Bash(first second:*) or Bash(first:*) if only one word.
permission_key_for_single_command() {
  local cmd="$1"
  if [[ -x "$BASH_SPLIT" ]]; then
    printf '%s' "$cmd" | "$BASH_SPLIT" | head -n1
    return
  fi
  # Fallback: awk heuristic (extended to 3 tokens for subcommand CLIs)
  cmd=$(printf '%s' "$cmd" | tr '\n' ' ' | sed 's/\\  */ /g; s/^[[:space:]]*//')
  local first_word second_word third_word
  first_word=$(printf '%s' "$cmd" | awk '{print $1}')
  second_word=$(printf '%s' "$cmd" | awk '{print $2}')
  third_word=$(printf '%s' "$cmd" | awk '{print $3}')
  if [[ -n "$third_word" && "$second_word" =~ ^[a-zA-Z] && "$third_word" =~ ^[a-zA-Z] ]]; then
    echo "Bash($first_word $second_word $third_word:*)"
  elif [[ -n "$second_word" ]]; then
    echo "Bash($first_word $second_word:*)"
  else
    echo "Bash($first_word:*)"
  fi
}

# Split a compound command on &&, ||, ; and | into individual sub-commands.
# Returns one sub-command per line (trimmed).
split_compound_command() {
  local cmd="$1"
  if [[ -x "$BASH_SPLIT" ]]; then
    printf '%s' "$cmd" | "$BASH_SPLIT"
    return
  fi
  # Fallback: original perl+awk approach
  cmd=$(printf '%s' "$cmd" | perl -pe 's/\\\n/ /g')
  printf '%s' "$cmd" | awk -v RS='(&&|\\|\\||;|\\|)' '{
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    if (length($0) > 0) print
  }'
}

# Format permission key based on tool type
format_permission_key() {
  local tool="$1"
  local input="$2"

  case "$tool" in
    Bash)
      local command
      command=$(echo "$input" | jq -r '.command // ""')
      permission_key_for_single_command "$command"
      ;;
    Read | Glob | Grep | Write | Edit | Agent | Task | WebFetch | WebSearch | AskUserQuestion | Skill | EnterPlanMode | ExitPlanMode | LSP | NotebookEdit | TaskCreate | TaskGet | TaskList | TaskUpdate | TaskOutput | TaskStop)
      # Simple tool names
      echo "$tool"
      ;;
    mcp__*)
      # MCP tools - use as-is
      echo "$tool"
      ;;
    *)
      # Unknown tools - use as-is
      echo "$tool"
      ;;
  esac
}

# Get the raw bash command for deny list checking
get_bash_command() {
  local input="$1"
  echo "$input" | jq -r '.command // ""'
}

# Format human-readable tool description for the dialog
format_tool_description() {
  local tool="$1"
  local input="$2"

  case "$tool" in
    Bash)
      local command description
      command=$(echo "$input" | jq -r '.command // ""')
      description=$(echo "$input" | jq -r '.description // ""')
      if [[ -n "$description" && "$description" != "null" ]]; then
        printf "Bash: %s\n\nCommand: %s" "$description" "$command"
      else
        printf "Bash: %s" "$command"
      fi
      ;;
    Read)
      local file_path
      file_path=$(echo "$input" | jq -r '.file_path // ""')
      printf "Read file: %s" "$file_path"
      ;;
    Write)
      local file_path
      file_path=$(echo "$input" | jq -r '.file_path // ""')
      printf "Write file: %s" "$file_path"
      ;;
    Edit)
      local file_path
      file_path=$(echo "$input" | jq -r '.file_path // ""')
      printf "Edit file: %s" "$file_path"
      ;;
    Task)
      local desc subagent
      desc=$(echo "$input" | jq -r '.description // ""')
      subagent=$(echo "$input" | jq -r '.subagent_type // ""')
      printf "Task: %s - %s" "$subagent" "$desc"
      ;;
    Agent)
      local desc subagent
      desc=$(echo "$input" | jq -r '.description // ""')
      subagent=$(echo "$input" | jq -r '.subagent_type // ""')
      printf "Agent: %s - %s" "$subagent" "$desc"
      ;;
    WebFetch)
      local url
      url=$(echo "$input" | jq -r '.url // ""')
      printf "WebFetch: %s" "$url"
      ;;
    WebSearch)
      local query
      query=$(echo "$input" | jq -r '.query // ""')
      printf "WebSearch: %s" "$query"
      ;;
    Skill)
      local skill
      skill=$(echo "$input" | jq -r '.skill // ""')
      printf "Skill: /%s" "$skill"
      ;;
    mcp__serena__*)
      local short_name="${tool#mcp__serena__}"
      printf "Serena: %s" "$short_name"
      ;;
    mcp__encore__*)
      local short_name="${tool#mcp__encore__}"
      printf "Encore: %s" "$short_name"
      ;;
    *)
      printf "%s" "$tool"
      ;;
  esac
}

# Check if a single permission key matches any pattern in a permission array
check_single_key_against_array() {
  local key="$1"
  local array="$2"

  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue

    # Exact match
    if [[ "$key" == "$pattern" ]]; then
      return 0
    fi

    # Pattern with wildcard at end (e.g., "Bash(npm:*)")
    if [[ "$pattern" == *":*)" ]]; then
      local prefix="${pattern%:*)}"
      if [[ "$key" == "$prefix"* ]]; then
        return 0
      fi
    fi

    # Simple tool name match (e.g., "Read" matches "Read")
    if [[ "$pattern" == "$tool_name" ]]; then
      return 0
    fi

    # MCP wildcard (e.g., "mcp__encore__*")
    if [[ "$pattern" == *"__*" ]]; then
      local mcp_prefix="${pattern%__*}__"
      if [[ "$key" == "$mcp_prefix"* ]]; then
        return 0
      fi
    fi
  done <<<"$array"

  return 1
}

# Check if a permission key matches any pattern in an array.
# For Bash compound commands (&&, ||, ;, |), checks that ALL sub-commands match.
check_permission_array() {
  local key="$1"
  local array_name="$2"

  # Get the array from settings
  local array
  array=$(jq -r ".$array_name // [] | .[]" "$SETTINGS_FILE" 2>/dev/null) || return 1

  # For non-Bash tools, just check the single key
  if [[ "$tool_name" != "Bash" ]]; then
    check_single_key_against_array "$key" "$array"
    return $?
  fi

  # For Bash: get the raw command and split into sub-commands
  local command
  command=$(echo "$tool_input" | jq -r '.command // ""')
  local sub_commands
  sub_commands=$(split_compound_command "$command")

  # Also get raw sub-commands for exact-key matching
  local raw_subs
  raw_subs=$(printf '%s' "$command" | awk -v RS='(&&|\\|\\||;|\\|)' '{
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    if (length($0) > 0) print
  }')

  # If there are no sub-commands (shouldn't happen), fall back to single key check
  if [[ -z "$sub_commands" ]]; then
    check_single_key_against_array "$key" "$array"
    return $?
  fi

  # Zip bash-split keys with raw sub-commands
  local -a key_arr raw_arr
  mapfile -t key_arr <<<"$sub_commands"
  mapfile -t raw_arr <<<"$raw_subs"

  # Every sub-command must match (wildcard key OR exact key)
  for idx in "${!key_arr[@]}"; do
    local sub_cmd="${key_arr[$idx]}"
    [[ -z "$sub_cmd" ]] && continue
    local sub_key
    if [[ "$sub_cmd" == Bash\(* ]]; then
      sub_key="$sub_cmd"
    else
      sub_key=$(permission_key_for_single_command "$sub_cmd")
    fi
    if ! check_single_key_against_array "$sub_key" "$array"; then
      # Wildcard key didn't match — try exact key from raw command text
      local raw="${raw_arr[$idx]:-}"
      raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ -z "$raw" ]] || ! check_single_key_against_array "Bash($raw)" "$array"; then
        return 1
      fi
    fi
  done

  return 0
}

# Add permission to settings file
add_permission() {
  local key="$1"
  local array_name="$2"

  # Ensure settings file exists with proper structure
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo '{"permissions":{"allow":[],"deny":[],"ask":[]}}' >"$SETTINGS_FILE"
  fi

  # Add to the array if not already present
  local tmp_file
  tmp_file=$(mktemp)
  jq --arg key "$key" ".${array_name} += [\$key] | .${array_name} |= unique" "$SETTINGS_FILE" >"$tmp_file"
  mv "$tmp_file" "$SETTINGS_FILE"
}

# Log missed permission checks (not in allow or deny lists)
log_missed_permission() {
  local tool="$1"
  local key="$2"
  local input="$3"

  local log_file="$HOME/.claude/permission-prompt-log.txt"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local description
  description=$(format_tool_description "$tool" "$input" | tr '\n' '\\n')

  local entry="[${timestamp}] MISSED tool=${tool} key=\"${key}\" description=\"${description}\""

  if [[ "$tool" == "Bash" ]]; then
    local command
    command=$(echo "$input" | jq -r '.command // ""')
    entry="${entry} command=\"${command}\""
  fi

  echo "$entry" >>"$log_file"
}

# Main logic
permission_key=$(format_permission_key "$tool_name" "$tool_input")

# For Bash commands, also check the actual command against deny patterns.
# For compound commands, if ANY sub-command is denied, deny the whole thing.
check_bash_command_denied() {
  local cmd="$1"
  [[ -z "$cmd" ]] && return 1

  local deny_patterns
  deny_patterns=$(jq -r '.permissions.deny // [] | .[]' "$SETTINGS_FILE" 2>/dev/null) || return 1

  local sub_commands
  sub_commands=$(split_compound_command "$cmd")

  while IFS= read -r sub_cmd; do
    [[ -z "$sub_cmd" ]] && continue
    local sub_key
    if [[ "$sub_cmd" == Bash\(* ]]; then
      sub_key="$sub_cmd"
    else
      sub_key=$(permission_key_for_single_command "$sub_cmd")
    fi
    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      if [[ "$pattern" == Bash\(* ]]; then
        local cmd_pattern="${pattern#Bash(}"
        cmd_pattern="${cmd_pattern%:\*)}"
        if [[ "$sub_key" == "Bash($cmd_pattern"* || "$sub_cmd" == "$cmd_pattern"* ]]; then
          return 0
        fi
      fi
    done <<<"$deny_patterns"
  done <<<"$sub_commands"
  return 1
}

# Check deny FIRST (deny takes precedence)
if check_permission_array "$permission_key" "permissions.deny"; then
  # Explicitly denied by key
  hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Permission denied by ralph settings"}}'
  exit 0
fi

# For Bash, also check if the actual command matches any deny pattern
if [[ "$tool_name" == "Bash" ]]; then
  bash_command=$(get_bash_command "$tool_input")
  if check_bash_command_denied "$bash_command"; then
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command matches deny pattern"}}'
    exit 0
  fi
fi

# Auto-approve harmless tools in interactive (non-ralph) sessions.
# These tools don't modify files or run commands, so they are safe to allow
# without prompting. This list is intentionally NOT in settings.local.json
# because that would also auto-approve them for ralph sessions.
INTERACTIVE_AUTO_APPROVE_TOOLS=(Agent Task ExitPlanMode AskUserQuestion)
if [[ "$OLLO_MODE" != "ralph" ]]; then
  for _tool in "${INTERACTIVE_AUTO_APPROVE_TOOLS[@]}"; do
    if [[ "$tool_name" == "$_tool" ]]; then
      hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
      exit 0
    fi
  done
fi

# Check if already allowed
if check_permission_array "$permission_key" "permissions.allow"; then
  # Already allowed, return allow decision
  hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

# Neither allowed nor denied - need to prompt user.
# But first: if the tool was invoked with a timeout, deny immediately.
# The osascript dialog requires user interaction which can easily exceed the tool's
# timeout, causing the entire tool call to fail. Deny with instructions to retry
# without a timeout so the dialog has time to be answered.
has_timeout=$(echo "$tool_input" | jq 'has("timeout")')
if [[ "$has_timeout" == "true" ]]; then
  hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Tool was invoked with a timeout parameter, which may expire while waiting for permission approval. Retry this exact same tool call without the timeout parameter."}}'
  exit 0
fi

# Log this missed permission check
log_missed_permission "$tool_name" "$permission_key" "$tool_input"

# Prompt user via osascript
tool_description=$(format_tool_description "$tool_name" "$tool_input")

# Collect all permission sub-keys for this command
if [[ "$tool_name" == "Bash" ]]; then
  bash_cmd=$(echo "$tool_input" | jq -r '.command // ""')
  all_sub_keys=$(split_compound_command "$bash_cmd" | while IFS= read -r sub_cmd; do
    [[ -z "$sub_cmd" ]] && continue
    if [[ "$sub_cmd" == Bash\(* ]]; then
      echo "$sub_cmd"
    else
      permission_key_for_single_command "$sub_cmd"
    fi
  done | sort -u)
else
  all_sub_keys="$permission_key"
fi

# Filter to only keys not already in the allow list
allow_array=$(jq -r '.permissions.allow // [] | .[]' "$SETTINGS_FILE" 2>/dev/null) || allow_array=""
new_keys=""
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  if ! check_single_key_against_array "$k" "$allow_array"; then
    new_keys="${new_keys:+$new_keys
}$k"
  fi
done <<<"$all_sub_keys"

# Compute exact key for "Always allow exact" display
if [[ "$tool_name" == "Bash" ]]; then
  exact_key="Bash($bash_cmd)"
else
  exact_key="$permission_key"
fi

# Append to description
if [[ -n "$new_keys" ]]; then
  key_count=$(echo "$new_keys" | grep -c .)
  if [[ "$key_count" -eq 1 ]]; then
    tool_description=$(printf '%s\n\nAlways allow will apply to: %s\nAlways allow exact will apply to: %s' "$tool_description" "$new_keys" "$exact_key")
  else
    formatted_keys=$(echo "$new_keys" | sed 's/^/• /')
    tool_description=$(printf '%s\n\nAlways allow will apply to:\n%s\nAlways allow exact will apply to: %s' "$tool_description" "$formatted_keys" "$exact_key")
  fi
fi

# Escape special characters for osascript (double quotes and backslashes)
escaped_description=$(printf '%s' "$tool_description" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Build dialog options based on mode
if [[ "$OLLO_MODE" == "ralph" ]]; then
  dialog_options='{"Allow once", "Always allow", "Always allow exact", "Deny once", "Always deny", "Provide correction"}'
  dialog_title="Ralph Permission: $tool_name"
else
  dialog_options='{"Allow once", "Always allow", "Always allow exact", "Deny once", "Always deny", "Fallback to built-in"}'
  dialog_title="Permission: $tool_name"
fi

response=$(
  osascript <<APPLESCRIPT 2>/dev/null
choose from list $dialog_options with prompt "$escaped_description" with title "$dialog_title" default items {"Allow once"}
APPLESCRIPT
) || {
  # Dialog was cancelled - deny by default
  hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Permission dialog cancelled"}}'
  exit 0
}

# Parse response ("false" means user clicked Cancel)
case "$response" in
  "Allow once")
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    ;;
  "Always allow")
    persist_keys="${new_keys:-$permission_key}"
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      add_permission "$k" "permissions.allow"
    done <<<"$persist_keys"
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    ;;
  "Always allow exact")
    if [[ "$tool_name" == "Bash" ]]; then
      add_permission "Bash($bash_cmd)" "permissions.allow"
    else
      add_permission "$permission_key" "permissions.allow"
    fi
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    ;;
  "Deny once")
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Permission denied by user (once)"}}'
    ;;
  "Always deny")
    persist_keys="${new_keys:-$permission_key}"
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      add_permission "$k" "permissions.deny"
    done <<<"$persist_keys"
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Permission denied by user (always)"}}'
    ;;
  "Fallback to built-in")
    # Output empty JSON — no permissionDecision — so Claude Code's native prompt takes over
    hook_log_stdout '{}'
    ;;
  "Provide correction")
    # Walk up the process tree to find the ralph.sh ancestor and send SIGQUIT
    target_pid=$$
    while [[ "$target_pid" -gt 1 ]]; do
      target_pid=$(ps -o ppid= -p "$target_pid" | tr -d ' ')
      cmd_line=$(ps -o command= -p "$target_pid" 2>/dev/null || true)
      if [[ "$cmd_line" == *"ralph"* ]]; then
        kill -QUIT "$target_pid" 2>/dev/null || true
        break
      fi
    done
    # Deny the tool call — ralph's soft-interrupt handler takes over from here
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"User chose to provide a correction"}}'
    ;;
  *)
    # Cancel or unexpected response - deny by default
    hook_log_stdout '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Permission dialog cancelled or unrecognized response"}}'
    ;;
esac

exit 0
