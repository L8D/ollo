#!/usr/bin/env bash
set -euo pipefail

# Ollo Session Tracker
# Manages tmux sessions, phase transitions, and attention state for tickets.
#
# Usage: ollo session-tracker <command> [TICKET_ID]
# Commands: start, stop, restart, plan, decompose, execute, review, status, list, set-attention, clear-attention, set-ready, set-planning, prefill-planning-prompt

SESSIONS_DIR=".ollo/sessions"

# ─── Helper functions ────────────────────────────────────────────────────────

sessions_dir() {
  mkdir -p "$SESSIONS_DIR"
  echo "$SESSIONS_DIR"
}

session_file() {
  local ticket_id="$1"
  echo "$(sessions_dir)/$ticket_id.json"
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

write_session() {
  local ticket_id="$1"
  local jq_expr="$2"
  local file
  file=$(session_file "$ticket_id")

  # Create temp file in same directory for atomic write
  local tmp_file="${file}.tmp.$$"

  if [[ -f "$file" ]]; then
    jq "$jq_expr" <"$file" >"$tmp_file"
  else
    # If file doesn't exist, create from scratch
    echo '{}' | jq "$jq_expr" >"$tmp_file"
  fi

  mv "$tmp_file" "$file"
}

read_session() {
  local ticket_id="$1"
  local file
  file=$(session_file "$ticket_id")

  if [[ ! -f "$file" ]]; then
    echo "error: session file not found: $file" >&2
    return 1
  fi

  cat "$file"
}

# ─── Sub-command: start ──────────────────────────────────────────────────────

cmd_start() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker start <TICKET_ID>" >&2
    exit 1
  fi

  # Check if tmux session already exists
  if tmux has-session -t "$ticket_id" 2>/dev/null; then
    echo "Tmux session already exists: $ticket_id" >&2
    exit 0
  fi

  # Create tmux session running claude (in main worktree)
  tmux new-session -d -s "$ticket_id" -c "$(pwd)" -- direnv exec . ollo claude "$ticket_id"

  # Write initial session JSON
  write_session "$ticket_id" ".ticketId = \"$ticket_id\" | .tmuxSession = \"$ticket_id\" | .phase = \"created\" | .attention = false | .activeSubtask = null | .pid = null | .startedAt = \"$(now_iso)\" | .lastUpdated = \"$(now_iso)\""

  echo "Session started: $ticket_id" >&2
}

# ─── Sub-command: stop ───────────────────────────────────────────────────────

cmd_stop() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker stop <TICKET_ID>" >&2
    exit 1
  fi

  # Kill tmux session
  tmux kill-session -t "$ticket_id" 2>/dev/null || true

  # Remove session file
  local file
  file=$(session_file "$ticket_id")
  rm -f "$file"

  echo "Session stopped: $ticket_id" >&2
}

# ─── Sub-command: restart ────────────────────────────────────────────────────

cmd_restart() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker restart <TICKET_ID>" >&2
    exit 1
  fi

  cmd_stop "$ticket_id"
  cmd_start "$ticket_id"
}

# ─── Sub-command: plan ───────────────────────────────────────────────────────

cmd_plan() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker plan <TICKET_ID>" >&2
    exit 1
  fi

  # Kill current process and start claude
  tmux respawn-pane -k -t "$ticket_id" "direnv exec . ollo claude $ticket_id"

  # Update session JSON
  write_session "$ticket_id" ".phase = \"planning\" | .attention = false | .lastUpdated = \"$(now_iso)\""

  echo "Phase transition to planning: $ticket_id" >&2
}

# ─── Sub-command: decompose ──────────────────────────────────────────────────

cmd_decompose() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker decompose <TICKET_ID>" >&2
    exit 1
  fi

  # Kill current process and start decompose
  tmux respawn-pane -k -t "$ticket_id" "direnv exec . ollo claude $ticket_id -- -p '/ollo:decompose'"

  # Update session JSON
  write_session "$ticket_id" ".phase = \"decomposing\" | .attention = false | .lastUpdated = \"$(now_iso)\""

  echo "Phase transition to decomposing: $ticket_id" >&2
}

# ─── Sub-command: execute ────────────────────────────────────────────────────

cmd_execute() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker execute <TICKET_ID>" >&2
    exit 1
  fi

  # Kill current process and start execution
  if [[ "${OLLO_WORKTREES_ENABLED:-}" == "true" ]]; then
    # Get the main worktree path before switching
    local main_worktree
    main_worktree=$(pwd)

    tmux respawn-pane -k -t "$ticket_id" "worktree_path=\$(ollo use-worktree $ticket_id) && cd \"\$worktree_path\" && direnv exec . ollo ralph $ticket_id; cd $main_worktree && git worktree remove \"\$worktree_path\""
  else
    tmux respawn-pane -k -t "$ticket_id" "direnv exec . ollo ralph $ticket_id"
  fi

  # Update session JSON
  write_session "$ticket_id" ".phase = \"executing\" | .attention = false | .lastUpdated = \"$(now_iso)\""

  echo "Phase transition to executing: $ticket_id" >&2
}

# ─── Sub-command: review ─────────────────────────────────────────────────────

cmd_review() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker review <TICKET_ID>" >&2
    exit 1
  fi

  # Read ticket URL from kota
  local ticket_data
  ticket_data=$(kota tickets read "$ticket_id")

  local ticket_url
  ticket_url=$(echo "$ticket_data" | jq -r '.url')

  if [[ -z "$ticket_url" || "$ticket_url" == "null" ]]; then
    echo "error: could not get URL for ticket $ticket_id" >&2
    exit 1
  fi

  # Get documents
  local documents
  documents=$(kota documents list --ticket "$ticket_id")

  # Find plan document (title starts with "PLAN")
  local plan_doc_url
  plan_doc_url=$(echo "$documents" | jq -r '.[] | select(.title | startswith("PLAN")) | .url' | head -1)

  if [[ -z "$plan_doc_url" || "$plan_doc_url" == "null" ]]; then
    echo "No plan document found; opening ticket in browser" >&2
    open "$ticket_url"
  else
    echo "Opening plan document in browser" >&2
    open "$plan_doc_url"
  fi
}

# ─── Sub-command: status ──────────────────────────────────────────────────────

cmd_status() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker status <TICKET_ID>" >&2
    exit 1
  fi

  # Read session JSON
  local session_data
  if ! session_data=$(read_session "$ticket_id"); then
    exit 1
  fi

  # Check if tmux session exists
  local alive=false
  if tmux has-session -t "$ticket_id" 2>/dev/null; then
    alive=true
  fi

  # Output enriched JSON
  echo "$session_data" | jq ".alive = $alive"
}

# ─── Sub-command: list ───────────────────────────────────────────────────────

cmd_list() {
  local sessions_path
  sessions_path=$(sessions_dir)

  # Collect all sessions into array
  local sessions=()

  if [[ -d "$sessions_path" ]]; then
    for file in "$sessions_path"/*.json; do
      if [[ -f "$file" ]]; then
        # Check if tmux session exists and add alive field
        local ticket_id
        ticket_id=$(basename "$file" .json)

        local alive=false
        if tmux has-session -t "$ticket_id" 2>/dev/null; then
          alive=true
        fi

        local session_data
        session_data=$(cat "$file" | jq ".alive = $alive")
        sessions+=("$session_data")
      fi
    done
  fi

  # Output as JSON array
  if [[ ${#sessions[@]} -eq 0 ]]; then
    echo "[]"
  else
    printf '%s\n' "${sessions[@]}" | jq -s .
  fi
}

# ─── Sub-command: set-attention ──────────────────────────────────────────────

cmd_set_attention() {
  local ticket_id="$1"

  # Graceful no-op if ticket_id is empty
  if [[ -z "$ticket_id" ]]; then
    exit 0
  fi

  # Graceful no-op if session file doesn't exist
  if [[ ! -f "$(session_file "$ticket_id")" ]]; then
    exit 0
  fi

  write_session "$ticket_id" ".attention = true | .lastUpdated = \"$(now_iso)\""
}

# ─── Sub-command: clear-attention ────────────────────────────────────────────

cmd_clear_attention() {
  local ticket_id="$1"

  # Graceful no-op if ticket_id is empty
  if [[ -z "$ticket_id" ]]; then
    exit 0
  fi

  # Graceful no-op if session file doesn't exist
  if [[ ! -f "$(session_file "$ticket_id")" ]]; then
    exit 0
  fi

  write_session "$ticket_id" ".attention = false | .lastUpdated = \"$(now_iso)\""
}

# ─── Sub-command: set-ready ──────────────────────────────────────────────────

cmd_set_ready() {
  local ticket_id="$1"

  # Graceful no-op if ticket_id is empty
  if [[ -z "$ticket_id" ]]; then
    exit 0
  fi

  # Graceful no-op if session file doesn't exist
  if [[ ! -f "$(session_file "$ticket_id")" ]]; then
    exit 0
  fi

  write_session "$ticket_id" ".phase = \"ready\" | .lastUpdated = \"$(now_iso)\""
}

# ─── Sub-command: set-planning ───────────────────────────────────────────────

cmd_set_planning() {
  local ticket_id="$1"

  # Graceful no-op if ticket_id is empty
  if [[ -z "$ticket_id" ]]; then
    exit 0
  fi

  # Graceful no-op if session file doesn't exist
  if [[ ! -f "$(session_file "$ticket_id")" ]]; then
    exit 0
  fi

  write_session "$ticket_id" ".phase = \"planning\" | .lastUpdated = \"$(now_iso)\""
}

# ─── Sub-command: prefill-planning-prompt ────────────────────────────────────

cmd_prefill_planning_prompt() {
  local ticket_id="$1"

  if [[ -z "$ticket_id" ]]; then
    echo "Usage: ollo session-tracker prefill-planning-prompt <TICKET_ID>" >&2
    exit 1
  fi

  # Get ticket title from kota
  local title
  title=$(kota tickets read "$ticket_id" 2>/dev/null | jq -r '.title // ""' || true)

  # Build the prefill text: "TICKET_ID title" followed by two newlines
  # The two newlines create a visual separator for the user to type below
  local prefill_text
  prefill_text=$(printf '%s %s\n\n' "$ticket_id" "$title")

  # Use tmux send-keys with -l (literal) flag to insert text without
  # interpreting escape sequences. This does NOT press Enter/submit.
  tmux send-keys -t "$ticket_id" -l "$prefill_text"
}

# ─── Dispatcher ──────────────────────────────────────────────────────────────

subcmd="${1:-}"
shift || true

case "$subcmd" in
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  plan) cmd_plan "$@" ;;
  decompose) cmd_decompose "$@" ;;
  execute) cmd_execute "$@" ;;
  review) cmd_review "$@" ;;
  status) cmd_status "$@" ;;
  list) cmd_list ;;
  set-attention) cmd_set_attention "$@" ;;
  clear-attention) cmd_clear_attention "$@" ;;
  set-ready) cmd_set_ready "$@" ;;
  set-planning) cmd_set_planning "$@" ;;
  prefill-planning-prompt) cmd_prefill_planning_prompt "$@" ;;
  *)
    echo "Usage: ollo session-tracker <start|stop|restart|plan|decompose|execute|review|status|list|set-attention|clear-attention|set-ready|set-planning|prefill-planning-prompt> [TICKET_ID]" >&2
    exit 1
    ;;
esac
