#!/usr/bin/env bash
set -euo pipefail

# ─── Usage ───────────────────────────────────────────────────────────────────
# ollo state TICKET_ID
#
# Replays .ollo/sessions/TICKET_ID.jsonl to derive current session state.

TICKET_ID="${1:?Usage: ollo state TICKET_ID}"
SESSION_FILE=".ollo/sessions/$TICKET_ID.jsonl"

# ─── Derive state from event log ────────────────────────────────────────────
if [[ -f "$SESSION_FILE" ]]; then
  STATE="$(jq -s '
    reduce .[] as $e (
      {
        phase: "unknown",
        attention: false,
        activeSubtask: null,
        generation: 0,
        synced: false,
        tmuxSession: null,
        startedAt: null,
        lastUpdated: null
      };

      if $e.name == "TmuxSessionCreated" then
        .tmuxSession = $e.tmuxSession
        | .startedAt = $e.ts
        | .phase = "created"
        | .attention = false
        | .synced = false

      elif $e.name == "TmuxSessionDestroyed" then
        .phase = "stopped"

      elif $e.name == "ClaudeHookFired" then
        if $e.hook == "SessionStart" then
          (if .phase != "decomposing" then .phase = "ready" else . end)
          | .attention = false
        elif $e.hook == "Stop" then
          .attention = true
        elif $e.hook == "PermissionRequest" then
          .attention = true
        elif $e.hook == "UserPromptSubmit" then
          .attention = false
          | if .phase == "ready" or .phase == "planned" then .phase = "planning"
            elif .phase == "decomposed" then .phase = "decomposing"
            else . end
        elif $e.hook == "PreToolUse" then
          if $e.tool == "ExitPlanMode" then
            .attention = true
            | if .phase == "planning" then .phase = "planned"
              elif .phase == "decomposing" then .phase = "decomposed"
              else . end
          elif $e.tool == "AskUserQuestion" then
            .attention = true
          elif $e.tool == "Skill" and ($e.skill | tostring | test("decompose")) then
            .phase = "decomposing"
          else . end
        else . end

      elif $e.name == "GenerationReset" then
        .generation = $e.generation
        | .synced = false

      elif $e.name == "TicketDescriptionUpdated" then
        .synced = true

      else . end

      | .lastUpdated = $e.ts
    )
  ' "$SESSION_FILE")"
else
  STATE='{"phase":"unknown","attention":false,"activeSubtask":null,"generation":0,"synced":false,"tmuxSession":null,"startedAt":null,"lastUpdated":null}'
fi

# ─── Enrich with alive check and ticketId ────────────────────────────────────
ALIVE=false
TMUX_SESSION="$(echo "$STATE" | jq -r '.tmuxSession // empty')"
if [[ -n "$TMUX_SESSION" ]] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  ALIVE=true
fi

echo "$STATE" | jq --arg ticketId "$TICKET_ID" --argjson alive "$ALIVE" \
  '. + {ticketId: $ticketId, alive: $alive}'
