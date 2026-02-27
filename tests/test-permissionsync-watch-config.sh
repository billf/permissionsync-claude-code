#!/usr/bin/env bash
# test-permissionsync-watch-config.sh — unit tests for permissionsync-watch-config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
CHANGES_LOG="${TMP_DIR}/.claude/config-changes.jsonl"
trap 'rm -rf "$TMP_DIR"' EXIT

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if [[ $expected == "$actual" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected: '${expected}'"
		echo "#   actual:   '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_exit() {
	local desc="$1" expected="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if [[ $expected == "$actual" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected exit: '${expected}'"
		echo "#   actual exit:   '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

run_hook() {
	local source="$1" file_path="${2:-}" session="${3:-sess-test}" cwd="${4:-/tmp}"
	local input
	input=$(jq -nc \
		--arg source "$source" \
		--arg file_path "$file_path" \
		--arg session "$session" \
		--arg cwd "$cwd" \
		'{source: $source, file_path: $file_path, session_id: $session, cwd: $cwd}')
	HOME="$TMP_DIR" bash "${SCRIPT_DIR}/../permissionsync-watch-config.sh" <<<"$input"
}

# Settings file with both hooks present
GOOD_SETTINGS="${TMP_DIR}/settings-good.json"
jq -nc '{
  "hooks": {
    "PermissionRequest": [{"matcher":"*","hooks":[{"type":"command","command":"/home/user/.claude/hooks/log-permission-auto.sh"}]}],
    "PostToolUse": [{"matcher":"*","hooks":[{"type":"command","command":"/home/user/.claude/hooks/log-confirmed.sh"}]}]
  }
}' >"$GOOD_SETTINGS"

# Settings file with PermissionRequest hook missing
MISSING_PERMREQ="${TMP_DIR}/settings-no-permreq.json"
jq -nc '{
  "hooks": {
    "PostToolUse": [{"matcher":"*","hooks":[{"type":"command","command":"/home/user/.claude/hooks/log-confirmed.sh"}]}]
  }
}' >"$MISSING_PERMREQ"

# Settings file with PostToolUse hook missing
MISSING_POSTUSE="${TMP_DIR}/settings-no-postuse.json"
jq -nc '{
  "hooks": {
    "PermissionRequest": [{"matcher":"*","hooks":[{"type":"command","command":"/home/user/.claude/hooks/log-permission-auto.sh"}]}]
  }
}' >"$MISSING_POSTUSE"

echo "TAP version 13"

# --- Test 1: Non-user_settings source exits 0, no log ---
run_hook "project_settings" "$GOOD_SETTINGS"
exit_code=$?
assert_exit "non-user_settings source exits 0" "0" "$exit_code"

log_lines=0
[[ -f "$CHANGES_LOG" ]] && log_lines=$(wc -l <"$CHANGES_LOG" | tr -d ' ')
assert_eq "non-user_settings source: no log entry" "0" "$log_lines"

# --- Test 2: user_settings with intact hooks logs and exits 0 ---
set +e
run_hook "user_settings" "$GOOD_SETTINGS" 2>/dev/null
exit_code=$?
set -e
assert_exit "user_settings intact hooks exits 0" "0" "$exit_code"

log_lines=$(wc -l <"$CHANGES_LOG" | tr -d ' ')
assert_eq "user_settings intact hooks: one log entry" "1" "$log_lines"

hooks_intact=$(jq -r '.hooks_intact' "$CHANGES_LOG")
assert_eq "log entry has hooks_intact=true" "true" "$hooks_intact"

# --- Test 3: user_settings with missing PermissionRequest hook exits 2 ---
set +e
run_hook "user_settings" "$MISSING_PERMREQ" 2>/dev/null
exit_code=$?
set -e
assert_exit "missing PermissionRequest hook exits 2" "2" "$exit_code"

# --- Test 4: user_settings with missing PostToolUse hook exits 2 ---
set +e
run_hook "user_settings" "$MISSING_POSTUSE" 2>/dev/null
exit_code=$?
set -e
assert_exit "missing PostToolUse hook exits 2" "2" "$exit_code"

# --- Test 5: Log record has expected fields ---
log_source=$(jq -r 'select(.hooks_intact == true) | .source' "$CHANGES_LOG")
assert_eq "log entry has correct source" "user_settings" "$log_source"

log_file=$(jq -r 'select(.hooks_intact == true) | .file_path' "$CHANGES_LOG")
assert_eq "log entry has correct file_path" "$GOOD_SETTINGS" "$log_file"

log_ts=$(jq -r 'select(.hooks_intact == true) | .timestamp' "$CHANGES_LOG")
TEST_NUM=$((TEST_NUM + 1))
if [[ $log_ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
	echo "ok ${TEST_NUM} - log entry timestamp is ISO 8601"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - log entry timestamp should be ISO 8601, got: '$log_ts'"
	FAIL=$((FAIL + 1))
fi

# --- Test 6: Missing settings file exits 0 ---
set +e
run_hook "user_settings" "${TMP_DIR}/nonexistent-settings.json" 2>/dev/null
exit_code=$?
set -e
assert_exit "missing settings file exits 0" "0" "$exit_code"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
