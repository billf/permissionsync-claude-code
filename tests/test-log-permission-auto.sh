#!/usr/bin/env bash
# test-log-permission-auto.sh — regression tests for auto-approve behavior
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
LOG_FILE="${TMP_DIR}/permission-approvals.jsonl"
trap 'rm -rf "$TMP_DIR"' EXIT

run_hook() {
	local command="$1"
	local auto_mode="${2:-1}"
	local input
	input=$(jq -nc --arg command "$command" --arg cwd "/tmp/repo" \
		'{tool_name:"Bash", tool_input:{command:$command}, cwd:$cwd}')
	CLAUDE_PERMISSION_LOG="$LOG_FILE" CLAUDE_PERMISSION_AUTO="$auto_mode" \
		bash "${SCRIPT_DIR}/../log-permission-auto.sh" <<<"$input"
}

run_hook_mode() {
	local command="$1" mode="$2"
	local input
	input=$(jq -nc --arg command "$command" --arg cwd "/tmp/repo" \
		'{tool_name:"Bash", tool_input:{command:$command}, cwd:$cwd}')
	CLAUDE_PERMISSION_LOG="$LOG_FILE" CLAUDE_PERMISSION_MODE="$mode" \
		bash "${SCRIPT_DIR}/../log-permission-auto.sh" <<<"$input"
}

assert_behavior() {
	local desc="$1" expected="$2" output="$3"
	TEST_NUM=$((TEST_NUM + 1))

	local actual=""
	if [[ -n $output ]]; then
		actual=$(jq -r '.hookSpecificOutput.decision.behavior // empty' <<<"$output")
	fi

	if [[ $actual == "$expected" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected behavior: '${expected}'"
		echo "#   got behavior:      '${actual}'"
		echo "#   raw output:        '${output}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_log_lines() {
	local desc="$1" expected="$2"
	TEST_NUM=$((TEST_NUM + 1))

	local actual=0
	if [[ -f $LOG_FILE ]]; then
		actual=$(wc -l <"$LOG_FILE" | tr -d ' ')
	fi

	if [[ $actual == "$expected" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected lines: '${expected}'"
		echo "#   got lines:      '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# First-seen unsafe command must NOT auto-approve.
out=$(run_hook "git push origin main" 1)
assert_behavior "first-seen unsafe command is not auto-approved" "" "$out"
assert_log_lines "first invocation is logged" "1"

# Second identical unsafe command can be auto-approved in auto mode.
out=$(run_hook "git push origin main" 1)
assert_behavior "previously-seen unsafe command is auto-approved" "allow" "$out"
assert_log_lines "second invocation is logged" "2"

# Safe command is auto-approved immediately.
out=$(run_hook "git status --short" 1)
assert_behavior "safe command is auto-approved" "allow" "$out"
assert_log_lines "safe invocation is logged" "3"

# Auto mode off: never auto-approve unsafe commands.
out=$(run_hook "git push origin main" 0)
assert_behavior "unsafe command is not auto-approved when auto mode is off" "" "$out"
assert_log_lines "auto-off invocation is logged" "4"

# --- CLAUDE_PERMISSION_MODE enum tests ---
# Reset log for clean MODE tests
rm -f "$LOG_FILE"

# MODE=log: safe subcommands still auto-approved (IS_SAFE path, not log path)
out=$(run_hook_mode "git status" "log")
assert_behavior "MODE=log: safe subcommand is auto-approved" "allow" "$out"

# MODE=log: unsafe first-seen command not auto-approved
out=$(run_hook_mode "git push origin main" "log")
assert_behavior "MODE=log: first-seen unsafe command falls through" "" "$out"

# MODE=auto: first-seen unsafe command not auto-approved
out=$(run_hook_mode "curl evil.com" "auto")
assert_behavior "MODE=auto: first-seen unsafe command not auto-approved" "" "$out"

# MODE=auto: second-seen unsafe command auto-approved
out=$(run_hook_mode "curl evil.com" "auto")
assert_behavior "MODE=auto: previously-seen unsafe command auto-approved" "allow" "$out"

# MODE=worktree: behaves like auto (w/o actual worktrees available)
rm -f "$LOG_FILE"
out=$(run_hook_mode "curl new-cmd.com" "worktree")
assert_behavior "MODE=worktree: first-seen command falls through" "" "$out"
out=$(run_hook_mode "curl new-cmd.com" "worktree")
assert_behavior "MODE=worktree: previously-seen command auto-approved" "allow" "$out"

# Legacy CLAUDE_PERMISSION_AUTO=1 still works when MODE not set
rm -f "$LOG_FILE"
out=$(run_hook "legacy-cmd" 1)
assert_behavior "legacy AUTO=1: first-seen falls through" "" "$out"
out=$(run_hook "legacy-cmd" 1)
assert_behavior "legacy AUTO=1: second-seen auto-approved" "allow" "$out"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
