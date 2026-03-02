#!/usr/bin/env bash
# permissionsync-sync-on-end.sh: SessionEnd hook — auto-promotes JSONL rules on session exit
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read and parse stdin — SessionEnd payload contains a reason field
INPUT=$(</dev/stdin)
REASON=$(jq -r '.reason // ""' <<<"$INPUT")

# /clear resets the session without ending it; don't promote rules from an aborted session
if [[ $REASON == "clear" ]]; then
	exit 0
fi

SYNC="${SCRIPT_DIR}/permissionsync-sync.sh"
if [[ -x $SYNC ]]; then
	# Derive log dir from the sync script's location; follow CLAUDE_PERMISSION_LOG if set
	LOG_DIR="$(dirname "${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}")"
	SYNC_ERR_LOG="${LOG_DIR}/sync-on-end-errors.log"

	# Suppress stdout (don't block Claude), capture stderr to a recoverable log file.
	# Always exit 0 — a failed sync must not interrupt Claude Code startup/shutdown.
	if ! "$SYNC" --from-confirmed --apply >/dev/null 2>>"$SYNC_ERR_LOG"; then
		echo "permissionsync-sync-on-end: sync failed; see $SYNC_ERR_LOG" >&2
	fi
fi
exit 0
