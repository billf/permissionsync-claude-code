#!/usr/bin/env bash
# permissionsync-sync-on-end.sh: SessionEnd hook — auto-promotes JSONL rules on session exit
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read stdin (reason field) but don't use it — sync regardless
true </dev/stdin

SYNC="${SCRIPT_DIR}/sync-permissions.sh"
if [[ -x $SYNC ]]; then
	"$SYNC" --apply >/dev/null 2>&1 || true
fi
exit 0
