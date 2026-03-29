#!/usr/bin/env bash
# hook-debug.sh — source this at the top of any ollo hook script
# Logs stderr, stdout (via hook_log_stdout), and exit code to ~/.ollo/logs/hooks.log
#
# Usage:
#   source "$OLLO_HOME/lib/hook-debug.sh"
#
# Environment variables:
#   OLLO_HOOK_LOG=false          — disable logging entirely (source becomes a no-op)
#   OLLO_HOOK_LOG_MAX_SIZE=N     — max log file size in bytes before rotation (default: 5242880 = 5MB)

# Opt-out: define a passthrough hook_log_stdout and return
if [[ "${OLLO_HOOK_LOG:-true}" == "false" ]]; then
  hook_log_stdout() { printf '%s\n' "$1"; }
  return 0
fi

_HOOK_LOG_DIR="$HOME/.ollo/logs"
_HOOK_LOG_FILE="$_HOOK_LOG_DIR/hooks.log"
_HOOK_LOG_MAX="${OLLO_HOOK_LOG_MAX_SIZE:-5242880}"

mkdir -p "$_HOOK_LOG_DIR"

# Rotate if too large
if [[ -f "$_HOOK_LOG_FILE" ]] && (($(stat -f%z "$_HOOK_LOG_FILE" 2>/dev/null || echo 0) > _HOOK_LOG_MAX)); then
  mv "$_HOOK_LOG_FILE" "$_HOOK_LOG_FILE.1"
fi

# Header
printf '═══ [%s] PID=%s SCRIPT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$0" >>"$_HOOK_LOG_FILE"

# Save original stderr, then fork stderr to log + real stderr
exec 3>&2
exec 2> >(tee -a "$_HOOK_LOG_FILE" >&3)

# EXIT trap to log exit code
_hook_debug_on_exit() {
  local code=$?
  # Restore stderr so the trap itself doesn't write through the dead tee
  exec 2>&3 3>&-
  printf -- '--- exit: %d (%s)\n\n' "$code" "$0" >>"$_HOOK_LOG_FILE" 2>/dev/null
}
trap '_hook_debug_on_exit' EXIT

# Helper: emit a line to stdout AND log it
hook_log_stdout() {
  local line="$1"
  printf '%s\n' "$line"
  printf '[stdout] %s\n' "$line" >>"$_HOOK_LOG_FILE" 2>/dev/null
}
