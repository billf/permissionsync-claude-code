#!/usr/bin/env bash
# test-peel-indirection.sh — unit tests for peel_indirection()
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../permissionsync-lib.sh
source "${SCRIPT_DIR}/../permissionsync-lib.sh"

PASS=0
FAIL=0
TEST_NUM=0

assert_peeled() {
	local input="$1" expected_cmd="$2" expected_chain="${3:-}"
	TEST_NUM=$((TEST_NUM + 1))

	peel_indirection "$input"

	if [[ $PEELED_COMMAND == "$expected_cmd" ]] && [[ $INDIRECTION_CHAIN == "$expected_chain" ]]; then
		echo "ok ${TEST_NUM} - ${input}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${input}"
		echo "#   expected cmd:   '${expected_cmd}'"
		echo "#   got cmd:        '${PEELED_COMMAND}'"
		echo "#   expected chain: '${expected_chain}'"
		echo "#   got chain:      '${INDIRECTION_CHAIN}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# No indirection
assert_peeled "git status" "git status" ""
assert_peeled "ls -la" "ls -la" ""
assert_peeled "echo hello" "echo hello" ""

# Simple prefix indirection
assert_peeled "sudo git push" "git push" "sudo"
assert_peeled "nice git status" "git status" "nice"
assert_peeled "nohup git push" "git push" "nohup"
assert_peeled "time git status" "git status" "time"
assert_peeled "command git status" "git status" "command"

# Prefix with flags
assert_peeled "sudo -u root git push" "git push" "sudo"

# env (prefix_kv)
assert_peeled "env git status" "git status" "env"
assert_peeled "env FOO=bar git status" "git status" "env"
assert_peeled "env FOO=bar BAZ=qux git status" "git status" "env"

# xargs
assert_peeled "xargs git status" "git status" "xargs"
assert_peeled "xargs -I {} git status" "git status" "xargs"

# shell -c
assert_peeled "bash -c 'git status'" "git status" "bash"
assert_peeled "sh -c 'git status'" "git status" "sh"
assert_peeled 'bash -c "git status"' "git status" "bash"
assert_peeled "bash -c git status" "git status" "bash"

# Chained indirection
assert_peeled "sudo env FOO=bar git push" "git push" "sudo env"
assert_peeled "env FOO=bar sudo git push" "git push" "env sudo"

# Single word command (no indirection possible)
assert_peeled "ls" "ls" ""

# Empty input
assert_peeled "" "" ""

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
