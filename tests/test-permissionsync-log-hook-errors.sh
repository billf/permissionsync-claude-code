#!/usr/bin/env bash
# test-permissionsync-log-hook-errors.sh — unit tests for permissionsync-log-hook-errors.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
BASE_LOG="${TMP_DIR}/permission-approvals.jsonl"
ERRORS_LOG="${TMP_DIR}/hook-errors.jsonl"
MALICIOUS_LIB_DIR="$(mktemp -d /tmp/permissionsync-malicious-lib.XXXXXX)"
trap 'rm -rf "$TMP_DIR" "$MALICIOUS_LIB_DIR"' EXIT

run_hook() {
	local tool_name="$1" tool_input_json="$2" error="${3:-}" error_msg="${4:-}" lib_dir="${5:-}"
	local input
	input=$(jq -nc \
		--arg tool "$tool_name" \
		--argjson input "$tool_input_json" \
		--arg error "$error" \
		--arg error_message "$error_msg" \
		--arg cwd "/tmp/repo" \
		--arg session "sess-test" \
		'{tool_name: $tool, tool_input: $input, error: $error, error_message: $error_message, cwd: $cwd, session_id: $session}')
	if [[ -n $lib_dir ]]; then
		CLAUDE_PERMISSION_LOG="$BASE_LOG" PERMISSIONSYNC_LIB_DIR="$lib_dir" \
			bash "${SCRIPT_DIR}/../permissionsync-log-hook-errors.sh" <<<"$input"
	else
		CLAUDE_PERMISSION_LOG="$BASE_LOG" \
			bash "${SCRIPT_DIR}/../permissionsync-log-hook-errors.sh" <<<"$input"
	fi
}

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

echo "TAP version 13"

# --- Test 1: Appends record to hook-errors.jsonl ---
run_hook "Bash" '{"command":"git push --force"}' "permission_denied" "User denied this operation"

lines=$(wc -l <"$ERRORS_LOG" | tr -d ' ')
assert_eq "Appends record to hook-errors.jsonl" "1" "$lines"

# --- Test 2: Correct tool and rule fields ---
tool=$(jq -r '.tool' "$ERRORS_LOG")
assert_eq "tool field set correctly" "Bash" "$tool"

rule=$(jq -r '.rule' "$ERRORS_LOG")
assert_eq "rule field set correctly" "Bash(git push *)" "$rule"

# --- Test 3: error field populated from stdin ---
error=$(jq -r '.error' "$ERRORS_LOG")
assert_eq "error field populated" "permission_denied" "$error"

error_msg=$(jq -r '.error_message' "$ERRORS_LOG")
assert_eq "error_message field populated" "User denied this operation" "$error_msg"

# --- Test 3b: is_safe and indirection_chain fields present ---
is_safe=$(jq -r '.is_safe' "$ERRORS_LOG")
assert_eq "is_safe field present (non-empty)" "1" "$([ -n "$is_safe" ] && echo 1 || echo 0)"

indirection_chain=$(jq -r '.indirection_chain' "$ERRORS_LOG")
assert_eq "indirection_chain field present (non-null)" "1" "$([ "$indirection_chain" != "null" ] && echo 1 || echo 0)"

# --- Test 4: Empty tool_name guard exits 0 without writing ---
lines_before=$(wc -l <"$ERRORS_LOG" | tr -d ' ')
empty_input='{"tool_name":"","tool_input":{},"error":"","error_message":"","cwd":"/tmp","session_id":""}'
CLAUDE_PERMISSION_LOG="$BASE_LOG" \
	bash "${SCRIPT_DIR}/../permissionsync-log-hook-errors.sh" <<<"$empty_input"
lines_after=$(wc -l <"$ERRORS_LOG" | tr -d ' ')
assert_eq "empty tool_name: no record appended" "$lines_before" "$lines_after"

# --- Test 5: Read tool failure recorded correctly ---
run_hook "Read" '{"file_path":"/etc/shadow"}' "permission_denied" "Access denied"

read_rule=$(jq -r 'select(.tool == "Read") | .rule' "$ERRORS_LOG")
assert_eq "Read tool failure rule is 'Read'" "Read" "$read_rule"

# --- Test 6: Bash tool failure recorded correctly ---
run_hook "Bash" '{"command":"rm -rf /"}' "error" "dangerous command"

bash_rule=$(jq -r 'select(.base_command == "rm") | .rule' "$ERRORS_LOG")
assert_eq "Bash tool failure with rm records correctly" "Bash(rm *)" "$bash_rule"

# --- Test 7: Multiple failures accumulate ---
lines_final=$(wc -l <"$ERRORS_LOG" | tr -d ' ')
assert_eq "Multiple failures accumulate (3 records so far)" "3" "$lines_final"

# --- Test 8: untrusted PERMISSIONSYNC_LIB_DIR traversal is ignored ---
cat >"$MALICIOUS_LIB_DIR/permissionsync-lib.sh" <<'EOF'
build_rule_v2() {
	RULE="Bash(fake *)"
	BASE_COMMAND="fake"
	INDIRECTION_CHAIN=""
	IS_SAFE="true"
}
EOF
run_hook "Bash" '{"command":"git status --short"}' "error" "bad" "/nix/store/../../tmp/$(basename "$MALICIOUS_LIB_DIR")"
latest_rule=$(tail -n 1 "$ERRORS_LOG" | jq -r '.rule')
assert_eq "untrusted PERMISSIONSYNC_LIB_DIR traversal ignored" "Bash(git status *)" "$latest_rule"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
