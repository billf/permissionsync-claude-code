#!/usr/bin/env bash
# test-classify.sh — unit tests for is_safe_subcommand() and has_subcommands()
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/permissionsync-lib.sh
source "${SCRIPT_DIR}/../lib/permissionsync-lib.sh"

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

# gh safe subcommands (read-only)
assert_safe "gh" "status"
assert_safe "gh" "search"
assert_safe "gh" "help"
assert_safe "gh" "version"

# gh standalone safe (added)
assert_safe "gh" "browse"

# gh unsafe standalone subcommands (contain write operations)
assert_not_safe "gh" "pr"
assert_not_safe "gh" "issue"
assert_not_safe "gh" "repo"
assert_not_safe "gh" "release"
assert_not_safe "gh" "api"

# gh compound-key safe (3-arg form)
assert_safe_compound() {
	local binary="$1" subcmd="$2" sub_subcmd="$3"
	TEST_NUM=$((TEST_NUM + 1))

	if is_safe_subcommand "$binary" "$subcmd" "$sub_subcmd"; then
		echo "ok ${TEST_NUM} - ${binary} ${subcmd} ${sub_subcmd} is safe (compound)"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} ${subcmd} ${sub_subcmd} should be safe (compound)"
		FAIL=$((FAIL + 1))
	fi
}

assert_not_safe_compound() {
	local binary="$1" subcmd="$2" sub_subcmd="$3"
	TEST_NUM=$((TEST_NUM + 1))

	if ! is_safe_subcommand "$binary" "$subcmd" "$sub_subcmd"; then
		echo "ok ${TEST_NUM} - ${binary} ${subcmd} ${sub_subcmd} is not safe (compound)"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} ${subcmd} ${sub_subcmd} should NOT be safe (compound)"
		FAIL=$((FAIL + 1))
	fi
}

assert_safe_compound "gh" "pr" "list"
assert_safe_compound "gh" "pr" "view"
assert_safe_compound "gh" "pr" "diff"
assert_safe_compound "gh" "pr" "checks"
assert_safe_compound "gh" "pr" "status"
assert_safe_compound "gh" "issue" "list"
assert_safe_compound "gh" "issue" "view"
assert_safe_compound "gh" "issue" "status"
assert_safe_compound "gh" "repo" "view"
assert_safe_compound "gh" "repo" "list"
assert_safe_compound "gh" "run" "list"
assert_safe_compound "gh" "run" "view"
assert_safe_compound "gh" "auth" "status"

# gh compound-key unsafe (write operations)
assert_not_safe_compound "gh" "pr" "create"
assert_not_safe_compound "gh" "pr" "merge"
assert_not_safe_compound "gh" "issue" "create"
assert_not_safe_compound "gh" "repo" "clone"
assert_not_safe_compound "gh" "run" "cancel"

# rustup safe subcommands
assert_safe "rustup" "show"
assert_safe "rustup" "check"
assert_safe_compound "rustup" "toolchain" "list"
assert_safe_compound "rustup" "target" "list"
assert_safe_compound "rustup" "component" "list"

# rustup unsafe (write operations)
assert_not_safe "rustup" "update"
assert_not_safe "rustup" "install"
assert_not_safe "rustup" "uninstall"

# yarn safe subcommands
assert_safe "yarn" "ls"
assert_safe "yarn" "list"
assert_safe "yarn" "outdated"
assert_safe "yarn" "info"
assert_safe "yarn" "why"

# yarn unsafe
assert_not_safe "yarn" "install"
assert_not_safe "yarn" "add"
assert_not_safe "yarn" "remove"

# pnpm safe subcommands
assert_safe "pnpm" "ls"
assert_safe "pnpm" "list"
assert_safe "pnpm" "outdated"
assert_safe "pnpm" "info"
assert_safe "pnpm" "why"

# pnpm unsafe
assert_not_safe "pnpm" "install"
assert_not_safe "pnpm" "add"
assert_not_safe "pnpm" "remove"

# jj safe subcommands
assert_safe "jj" "status"
assert_safe "jj" "log"
assert_safe "jj" "diff"
assert_safe "jj" "show"
assert_safe_compound "jj" "branch" "list"
assert_safe_compound "jj" "op" "log"

# jj unsafe
assert_not_safe "jj" "commit"
assert_not_safe "jj" "edit"
assert_not_safe "jj" "abandon"
assert_not_safe "jj" "squash"

# terraform safe subcommands
assert_safe "terraform" "validate"
assert_safe "terraform" "show"
assert_safe "terraform" "providers"
assert_safe "terraform" "version"

# terraform unsafe
assert_not_safe "terraform" "apply"
assert_not_safe "terraform" "destroy"
assert_not_safe "terraform" "import"
assert_not_safe "terraform" "plan"

# Unknown binary
assert_not_safe "unknown_tool" "whatever"

# has_subcommands — original binaries
assert_has_subcommands "gh"
assert_has_subcommands "git"
assert_has_subcommands "cargo"
assert_has_subcommands "npm"
assert_has_subcommands "docker"
assert_has_subcommands "kubectl"
assert_has_subcommands "pip"
assert_has_subcommands "brew"
assert_has_subcommands "nix"

# has_subcommands — new binaries
assert_has_subcommands "rustup"
assert_has_subcommands "yarn"
assert_has_subcommands "pnpm"
assert_has_subcommands "jj"
assert_has_subcommands "terraform"

# No subcommands for always-safe or unknown binaries
assert_no_subcommands "fd"
assert_no_subcommands "rg"
assert_no_subcommands "bat"
assert_no_subcommands "ls"
assert_no_subcommands "cat"
assert_no_subcommands "unknown_tool"

# is_always_safe_binary tests
assert_always_safe() {
	local binary="$1"
	TEST_NUM=$((TEST_NUM + 1))
	if is_always_safe_binary "$binary"; then
		echo "ok ${TEST_NUM} - ${binary} is always safe"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} should be always safe"
		FAIL=$((FAIL + 1))
	fi
}

assert_not_always_safe() {
	local binary="$1"
	TEST_NUM=$((TEST_NUM + 1))
	if ! is_always_safe_binary "$binary"; then
		echo "ok ${TEST_NUM} - ${binary} is not always safe"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${binary} should NOT be always safe"
		FAIL=$((FAIL + 1))
	fi
}

assert_always_safe "bat"
assert_always_safe "delta"
assert_always_safe "difftastic"
assert_not_always_safe "fd"
assert_not_always_safe "rg"
assert_not_always_safe "git"
assert_not_always_safe "rm"
assert_not_always_safe "curl"
assert_not_always_safe "unknown_tool"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
