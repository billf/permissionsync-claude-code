#!/usr/bin/env bash
# test-classify.sh — unit tests for is_safe_subcommand() and has_subcommands()
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../permissionsync-lib.sh
source "${SCRIPT_DIR}/../permissionsync-lib.sh"

PASS=0
FAIL=0
TEST_NUM=0

assert_safe() {
	local binary="$1" subcmd="$2"
	TEST_NUM=$((TEST_NUM + 1))

	if is_safe_subcommand "$binary" "$subcmd"; then
		echo "ok ${TEST_NUM} - ${binary} ${subcmd} is safe"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} ${subcmd} should be safe"
		FAIL=$((FAIL + 1))
	fi
}

assert_not_safe() {
	local binary="$1" subcmd="$2"
	TEST_NUM=$((TEST_NUM + 1))

	if ! is_safe_subcommand "$binary" "$subcmd"; then
		echo "ok ${TEST_NUM} - ${binary} ${subcmd} is not safe"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} ${subcmd} should NOT be safe"
		FAIL=$((FAIL + 1))
	fi
}

assert_has_subcommands() {
	local binary="$1"
	TEST_NUM=$((TEST_NUM + 1))

	if has_subcommands "$binary"; then
		echo "ok ${TEST_NUM} - ${binary} has subcommands"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} should have subcommands"
		FAIL=$((FAIL + 1))
	fi
}

assert_no_subcommands() {
	local binary="$1"
	TEST_NUM=$((TEST_NUM + 1))

	if ! has_subcommands "$binary"; then
		echo "ok ${TEST_NUM} - ${binary} has no subcommands"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} should NOT have subcommands"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# git safe subcommands
assert_safe "git" "status"
assert_safe "git" "log"
assert_safe "git" "diff"
assert_safe "git" "show"
assert_safe "git" "branch"
assert_safe "git" "blame"

# git unsafe subcommands (SEC-02: config removed from safe list)
assert_not_safe "git" "push"
assert_not_safe "git" "pull"
assert_not_safe "git" "merge"
assert_not_safe "git" "rebase"
assert_not_safe "git" "reset"
assert_not_safe "git" "checkout"
assert_not_safe "git" "commit"
assert_not_safe "git" "config"
assert_not_safe "git" "stash"

# cargo safe (SEC-02: build/test/bench/doc removed)
assert_safe "cargo" "check"
assert_safe "cargo" "clippy"
assert_safe "cargo" "fmt"

# cargo unsafe
assert_not_safe "cargo" "publish"
assert_not_safe "cargo" "install"
assert_not_safe "cargo" "build"
assert_not_safe "cargo" "test"
assert_not_safe "cargo" "bench"
assert_not_safe "cargo" "doc"

# npm safe (SEC-02: test/start/audit removed)
assert_safe "npm" "ls"
assert_safe "npm" "list"
assert_safe "npm" "outdated"

# npm unsafe
assert_not_safe "npm" "install"
assert_not_safe "npm" "publish"
assert_not_safe "npm" "test"
assert_not_safe "npm" "start"
assert_not_safe "npm" "audit"

# nix safe (SEC-02: eval/build/develop/shell/flake removed)
assert_safe "nix" "log"
assert_safe "nix" "show-derivation"
assert_safe "nix" "path-info"

# nix unsafe
assert_not_safe "nix" "eval"
assert_not_safe "nix" "build"
assert_not_safe "nix" "develop"
assert_not_safe "nix" "shell"
assert_not_safe "nix" "flake"

# Unknown binary
assert_not_safe "unknown_tool" "whatever"

# has_subcommands
assert_has_subcommands "git"
assert_has_subcommands "cargo"
assert_has_subcommands "npm"
assert_has_subcommands "docker"
assert_has_subcommands "kubectl"
assert_has_subcommands "pip"
assert_has_subcommands "brew"
assert_has_subcommands "nix"

# No subcommands for unknown binaries
assert_no_subcommands "ls"
assert_no_subcommands "cat"
assert_no_subcommands "unknown_tool"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
