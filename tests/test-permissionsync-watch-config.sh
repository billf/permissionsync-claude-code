#!/usr/bin/env bash
# test-permissionsync-watch-config.sh — unit tests for permissionsync-watch-config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
CANONICAL_SETTINGS="${TMP_DIR}/.claude/settings.json"
CHANGES_LOG="${TMP_DIR}/.claude/config-changes.jsonl"
trap 'rm -rf "$TMP_DIR"' EXIT

# Ensure the .claude dir exists for canonical settings
mkdir -p "${TMP_DIR}/.claude"

HOOKS_DIR="${HOME}/.claude/hooks"

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

# Write a settings fixture to the canonical path the guard inspects ($HOME/.claude/settings.json).
# The guard always reads from this path (never trusts file_path from stdin).
write_canonical_settings() {
	local content="$1"
	printf '%s' "$content" >"$CANONICAL_SETTINGS"
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

# Generate fixture JSON with all 5 hooks present (using $HOME/.claude/hooks/ paths)
ALL_HOOKS_JSON=$(jq -nc \
	--arg perm "${HOOKS_DIR}/permissionsync-log-permission.sh" \
	--arg post "${HOOKS_DIR}/permissionsync-log-confirmed.sh" \
	--arg ptf "${HOOKS_DIR}/permissionsync-log-hook-errors.sh" \
	--arg cc "${HOOKS_DIR}/permissionsync-watch-config.sh" \
	--arg se "${HOOKS_DIR}/permissionsync-sync-on-end.sh" \
	'{hooks: {
		PermissionRequest: [{matcher:"*",hooks:[{type:"command",command:$perm}]}],
		PostToolUse: [{matcher:"*",hooks:[{type:"command",command:$post}]}],
		PostToolUseFailure: [{matcher:"*",hooks:[{type:"command",command:$ptf}]}],
		ConfigChange: [{hooks:[{type:"command",command:$cc}]}],
		SessionEnd: [{hooks:[{type:"command",command:$se}]}]
	}}')

# Generate fixture JSON with only PermissionRequest + PostToolUse (missing 3 new hooks)
# shellcheck disable=SC2034  # fixture available for future tests
MISSING_NEW_HOOKS_JSON=$(jq -nc \
	--arg perm "${HOOKS_DIR}/permissionsync-log-permission.sh" \
	--arg post "${HOOKS_DIR}/permissionsync-log-confirmed.sh" \
	'{hooks: {
		PermissionRequest: [{matcher:"*",hooks:[{type:"command",command:$perm}]}],
		PostToolUse: [{matcher:"*",hooks:[{type:"command",command:$post}]}]
	}}')

# Generate fixture JSON missing PermissionRequest only
MISSING_PERMREQ_JSON=$(jq -nc \
	--arg post "${HOOKS_DIR}/permissionsync-log-confirmed.sh" \
	--arg ptf "${HOOKS_DIR}/permissionsync-log-hook-errors.sh" \
	--arg cc "${HOOKS_DIR}/permissionsync-watch-config.sh" \
	--arg se "${HOOKS_DIR}/permissionsync-sync-on-end.sh" \
	'{hooks: {
		PostToolUse: [{matcher:"*",hooks:[{type:"command",command:$post}]}],
		PostToolUseFailure: [{matcher:"*",hooks:[{type:"command",command:$ptf}]}],
		ConfigChange: [{hooks:[{type:"command",command:$cc}]}],
		SessionEnd: [{hooks:[{type:"command",command:$se}]}]
	}}')

# Generate fixture JSON missing PostToolUse only
MISSING_POSTUSE_JSON=$(jq -nc \
	--arg perm "${HOOKS_DIR}/permissionsync-log-permission.sh" \
	--arg ptf "${HOOKS_DIR}/permissionsync-log-hook-errors.sh" \
	--arg cc "${HOOKS_DIR}/permissionsync-watch-config.sh" \
	--arg se "${HOOKS_DIR}/permissionsync-sync-on-end.sh" \
	'{hooks: {
		PermissionRequest: [{matcher:"*",hooks:[{type:"command",command:$perm}]}],
		PostToolUseFailure: [{matcher:"*",hooks:[{type:"command",command:$ptf}]}],
		ConfigChange: [{hooks:[{type:"command",command:$cc}]}],
		SessionEnd: [{hooks:[{type:"command",command:$se}]}]
	}}')

# Generate fixture JSON missing PostToolUseFailure only
MISSING_PTF_JSON=$(jq -nc \
	--arg perm "${HOOKS_DIR}/permissionsync-log-permission.sh" \
	--arg post "${HOOKS_DIR}/permissionsync-log-confirmed.sh" \
	--arg cc "${HOOKS_DIR}/permissionsync-watch-config.sh" \
	--arg se "${HOOKS_DIR}/permissionsync-sync-on-end.sh" \
	'{hooks: {
		PermissionRequest: [{matcher:"*",hooks:[{type:"command",command:$perm}]}],
		PostToolUse: [{matcher:"*",hooks:[{type:"command",command:$post}]}],
		ConfigChange: [{hooks:[{type:"command",command:$cc}]}],
		SessionEnd: [{hooks:[{type:"command",command:$se}]}]
	}}')

# Generate fixture JSON missing ConfigChange only
MISSING_CC_JSON=$(jq -nc \
	--arg perm "${HOOKS_DIR}/permissionsync-log-permission.sh" \
	--arg post "${HOOKS_DIR}/permissionsync-log-confirmed.sh" \
	--arg ptf "${HOOKS_DIR}/permissionsync-log-hook-errors.sh" \
	--arg se "${HOOKS_DIR}/permissionsync-sync-on-end.sh" \
	'{hooks: {
		PermissionRequest: [{matcher:"*",hooks:[{type:"command",command:$perm}]}],
		PostToolUse: [{matcher:"*",hooks:[{type:"command",command:$post}]}],
		PostToolUseFailure: [{matcher:"*",hooks:[{type:"command",command:$ptf}]}],
		SessionEnd: [{hooks:[{type:"command",command:$se}]}]
	}}')

# Generate fixture JSON missing SessionEnd only
MISSING_SE_JSON=$(jq -nc \
	--arg perm "${HOOKS_DIR}/permissionsync-log-permission.sh" \
	--arg post "${HOOKS_DIR}/permissionsync-log-confirmed.sh" \
	--arg ptf "${HOOKS_DIR}/permissionsync-log-hook-errors.sh" \
	--arg cc "${HOOKS_DIR}/permissionsync-watch-config.sh" \
	'{hooks: {
		PermissionRequest: [{matcher:"*",hooks:[{type:"command",command:$perm}]}],
		PostToolUse: [{matcher:"*",hooks:[{type:"command",command:$post}]}],
		PostToolUseFailure: [{matcher:"*",hooks:[{type:"command",command:$ptf}]}],
		ConfigChange: [{hooks:[{type:"command",command:$cc}]}]
	}}')

echo "TAP version 13"

# --- Test 1: Non-user_settings source exits 0, no log ---
write_canonical_settings "$ALL_HOOKS_JSON"
run_hook "project_settings" "$CANONICAL_SETTINGS"
exit_code=$?
assert_exit "non-user_settings source exits 0" "0" "$exit_code"

log_lines=0
[[ -f $CHANGES_LOG ]] && log_lines=$(wc -l <"$CHANGES_LOG" | tr -d ' ')
assert_eq "non-user_settings source: no log entry" "0" "$log_lines"

# --- Test 2: user_settings with all 5 hooks intact logs and exits 0 ---
write_canonical_settings "$ALL_HOOKS_JSON"
set +e
run_hook "user_settings" "$CANONICAL_SETTINGS" 2>/dev/null
exit_code=$?
set -e
assert_exit "user_settings intact hooks exits 0" "0" "$exit_code"

log_lines=$(wc -l <"$CHANGES_LOG" | tr -d ' ')
assert_eq "user_settings intact hooks: one log entry" "1" "$log_lines"

hooks_intact=$(jq -r '.hooks_intact' "$CHANGES_LOG")
assert_eq "log entry has hooks_intact=true" "true" "$hooks_intact"

# --- Test 3: user_settings with missing PermissionRequest hook exits 0 with stderr warning ---
write_canonical_settings "$MISSING_PERMREQ_JSON"
set +e
stderr_out=$(run_hook "user_settings" "$CANONICAL_SETTINGS" 2>&1 >/dev/null)
exit_code=$?
set -e
assert_exit "missing PermissionRequest hook exits 0 (warn-only)" "0" "$exit_code"

TEST_NUM=$((TEST_NUM + 1))
if echo "$stderr_out" | grep -q "WARNING"; then
	echo "ok ${TEST_NUM} - missing PermissionRequest hook prints WARNING to stderr"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - missing PermissionRequest hook should print WARNING to stderr, got: '$stderr_out'"
	FAIL=$((FAIL + 1))
fi

# --- Test 4: user_settings with missing PostToolUse hook exits 0 with stderr warning ---
write_canonical_settings "$MISSING_POSTUSE_JSON"
set +e
stderr_out=$(run_hook "user_settings" "$CANONICAL_SETTINGS" 2>&1 >/dev/null)
exit_code=$?
set -e
assert_exit "missing PostToolUse hook exits 0 (warn-only)" "0" "$exit_code"

TEST_NUM=$((TEST_NUM + 1))
if echo "$stderr_out" | grep -q "WARNING"; then
	echo "ok ${TEST_NUM} - missing PostToolUse hook prints WARNING to stderr"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - missing PostToolUse hook should print WARNING to stderr, got: '$stderr_out'"
	FAIL=$((FAIL + 1))
fi

# --- Test 5: Log record has expected fields ---
log_source=$(jq -r 'select(.hooks_intact == true) | .source' "$CHANGES_LOG")
assert_eq "log entry has correct source" "user_settings" "$log_source"

log_file=$(jq -r 'select(.hooks_intact == true) | .file_path' "$CHANGES_LOG")
assert_eq "log entry has correct file_path (from stdin)" "$CANONICAL_SETTINGS" "$log_file"

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
rm -f "$CANONICAL_SETTINGS"
set +e
run_hook "user_settings" "${TMP_DIR}/nonexistent-settings.json" 2>/dev/null
exit_code=$?
set -e
assert_exit "missing settings file exits 0" "0" "$exit_code"
# Restore canonical settings dir for remaining tests
mkdir -p "${TMP_DIR}/.claude"

# --- Test 7: missing PostToolUseFailure hook → HOOKS_INTACT=false ---
write_canonical_settings "$MISSING_PTF_JSON"
set +e
stderr_out=$(run_hook "user_settings" "$CANONICAL_SETTINGS" 2>&1 >/dev/null)
exit_code=$?
set -e
assert_exit "missing PostToolUseFailure hook exits 0 (warn-only)" "0" "$exit_code"

TEST_NUM=$((TEST_NUM + 1))
if echo "$stderr_out" | grep -q "WARNING"; then
	echo "ok ${TEST_NUM} - missing PostToolUseFailure hook prints WARNING to stderr"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - missing PostToolUseFailure hook should print WARNING to stderr, got: '$stderr_out'"
	FAIL=$((FAIL + 1))
fi

# --- Test 8: missing ConfigChange hook → HOOKS_INTACT=false ---
write_canonical_settings "$MISSING_CC_JSON"
set +e
stderr_out=$(run_hook "user_settings" "$CANONICAL_SETTINGS" 2>&1 >/dev/null)
exit_code=$?
set -e
assert_exit "missing ConfigChange hook exits 0 (warn-only)" "0" "$exit_code"

TEST_NUM=$((TEST_NUM + 1))
if echo "$stderr_out" | grep -q "WARNING"; then
	echo "ok ${TEST_NUM} - missing ConfigChange hook prints WARNING to stderr"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - missing ConfigChange hook should print WARNING to stderr, got: '$stderr_out'"
	FAIL=$((FAIL + 1))
fi

# --- Test 9: missing SessionEnd hook → HOOKS_INTACT=false ---
write_canonical_settings "$MISSING_SE_JSON"
set +e
stderr_out=$(run_hook "user_settings" "$CANONICAL_SETTINGS" 2>&1 >/dev/null)
exit_code=$?
set -e
assert_exit "missing SessionEnd hook exits 0 (warn-only)" "0" "$exit_code"

TEST_NUM=$((TEST_NUM + 1))
if echo "$stderr_out" | grep -q "WARNING"; then
	echo "ok ${TEST_NUM} - missing SessionEnd hook prints WARNING to stderr"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - missing SessionEnd hook should print WARNING to stderr, got: '$stderr_out'"
	FAIL=$((FAIL + 1))
fi

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
