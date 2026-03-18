#!/usr/bin/env bash
# Create (or reuse) a git worktree for a Kota ticket.
# Idempotent — exits cleanly if the worktree already exists.
#
# Usage: ollo use-worktree <TICKET_ID> [BASE_BRANCH]
#
# Env vars exported to .ollo/hooks/post-create-worktree:
#   OLLO_WORKTREE_MAIN        Absolute path to the main worktree
#   OLLO_WORKTREE_PATH        Absolute path to the new worktree
#   OLLO_WORKTREE_BRANCH      Branch name created/checked out
#   OLLO_WORKTREE_BASE_BRANCH Base branch (2nd arg or current branch)
#   OLLO_WORKTREE_TICKET_ID   Ticket ID (1st arg)
set -euo pipefail

if [[ -z "${OLLO_HOME:-}" ]]; then
  echo "error: OLLO_HOME is not set. Run via 'ollo' dispatcher or set OLLO_HOME." >&2
  exit 1
fi

OLLO_WORKTREE_TICKET_ID="${1:-}"
if [[ -z "$OLLO_WORKTREE_TICKET_ID" ]]; then
  echo "Usage: ollo use-worktree <TICKET_ID> [BASE_BRANCH]" >&2
  exit 1
fi

# Resolve main worktree via git, validate expected <root>/worktrees/main structure
MAIN_WORKTREE_PATH="$(git worktree list --porcelain | grep '^worktree ' | head -1 | cut -d' ' -f2)"
WORKTREE_DIR="$(basename "$MAIN_WORKTREE_PATH")"
WORKTREES_DIR="$(basename "$(dirname "$MAIN_WORKTREE_PATH")")"

if [[ "$WORKTREE_DIR" != "main" || "$WORKTREES_DIR" != "worktrees" ]]; then
  echo "error: ollo use-worktree expects the main worktree to be at <root>/worktrees/main" >&2
  echo "  Found main worktree at: $MAIN_WORKTREE_PATH" >&2
  echo "  Expected structure:     /path/to/root/worktrees/main" >&2
  exit 1
fi

WORKTREES_ROOT="$(dirname "$MAIN_WORKTREE_PATH")"

export OLLO_WORKTREE_MAIN="$MAIN_WORKTREE_PATH"
export OLLO_WORKTREE_PATH="$WORKTREES_ROOT/$OLLO_WORKTREE_TICKET_ID"
export OLLO_WORKTREE_TICKET_ID
export OLLO_WORKTREE_BASE_BRANCH="${2:-$(git -C "$OLLO_WORKTREE_MAIN" rev-parse --abbrev-ref HEAD)}"

# Idempotent: skip if worktree already exists
if [[ -d "$OLLO_WORKTREE_PATH" ]]; then
  echo "Worktree already exists: $OLLO_WORKTREE_PATH" >&2
  echo "$OLLO_WORKTREE_PATH"
  exit 0
fi

# Get branch name from Kota ticket
export OLLO_WORKTREE_BRANCH="$(kota tickets read "$OLLO_WORKTREE_TICKET_ID" | jq -r '.branchName')"
if [[ -z "$OLLO_WORKTREE_BRANCH" || "$OLLO_WORKTREE_BRANCH" == "null" ]]; then
  echo "error: could not determine branch name from kota ticket $OLLO_WORKTREE_TICKET_ID" >&2
  exit 1
fi

# Create worktree (reuse existing branch or create new)
cd "$OLLO_WORKTREE_MAIN"
if git show-ref --verify --quiet "refs/heads/$OLLO_WORKTREE_BRANCH"; then
  git worktree add "$OLLO_WORKTREE_PATH" "$OLLO_WORKTREE_BRANCH"
else
  git worktree add -b "$OLLO_WORKTREE_BRANCH" "$OLLO_WORKTREE_PATH" "$OLLO_WORKTREE_BASE_BRANCH"
fi

# Run project hook if present
HOOK="$OLLO_WORKTREE_PATH/.ollo/hooks/post-create-worktree"
if [[ -f "$HOOK" ]]; then
  cd "$OLLO_WORKTREE_PATH"
  # shellcheck source=/dev/null
  source "$HOOK"
fi

echo "$OLLO_WORKTREE_PATH"
