#!/usr/bin/env bash
# session-start.sh: SessionStart hook — show actionable drift notification when new rules are pending
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Drain stdin (Claude Code pipes hook input; we don't use it)
true </dev/stdin

SYNC="${SCRIPT_DIR}/permissionsync-sync.sh"
if [[ ! -x $SYNC ]]; then
	exit 0
fi

OUTPUT=$("$SYNC" --diff 2>/dev/null) || true
[[ -z $OUTPUT ]] && exit 0

NEW_COUNT=$(echo "$OUTPUT" | grep -c '^>' 2>/dev/null) || true
if [[ ${NEW_COUNT:-0} -gt 0 ]]; then
	echo "== permissionsync: ${NEW_COUNT} new rule(s) in approval log =="
	echo "Apply:  ${SCRIPT_DIR}/permissionsync-sync.sh --apply"
	echo "Refine: ${SCRIPT_DIR}/permissionsync-sync.sh --refine --apply"
	echo ""
	echo "$OUTPUT"
fi
exit 0
