#!/usr/bin/env bash
# permissionsync-worktree-create.sh: WorktreeCreate hook — seeds new worktree with root's settings.local.json
#
# Input (stdin): JSON {"name": "<slug>", "cwd": "<worktree-path>"}
# Output (stdout): absolute worktree path (required by Claude Code)
set -euo pipefail

INPUT=$(</dev/stdin)
WORKTREE_PATH=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[[ -z $WORKTREE_PATH ]] && exit 1

GIT_COMMON=$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir 2>/dev/null) || GIT_COMMON=""

if [[ -n $GIT_COMMON ]]; then
	ROOT=$(dirname "$GIT_COMMON")
	ROOT_SETTINGS="${ROOT}/.claude/settings.local.json"
	DEST_DIR="${WORKTREE_PATH}/.claude"
	DEST="${DEST_DIR}/settings.local.json"

	if [[ -f $ROOT_SETTINGS ]] && [[ ! -f $DEST ]]; then
		mkdir -p "$DEST_DIR" 2>/dev/null || true
		cp "$ROOT_SETTINGS" "$DEST" 2>/dev/null || true
	fi
fi

# Required: print absolute worktree path to stdout
printf '%s\n' "$WORKTREE_PATH"
