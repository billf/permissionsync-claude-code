#!/usr/bin/env bash
# test-permissionsync-worktree-create.sh — unit tests for permissionsync-worktree-create.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${SCRIPT_DIR}/../permissionsync-worktree-create.sh"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
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

echo "TAP version 13"

run_hook() {
	local cwd="$1"
	local name="${2:-test-wt}"
	jq -nc --arg cwd "$cwd" --arg name "$name" '{cwd: $cwd, name: $name}' | bash "$HOOK"
}

# Set up a real git repo with a genuine worktree for testing
REPO_DIR="${TMP_DIR}/repo"
WORKTREE_DIR="${TMP_DIR}/worktree-test-wt"
git init -q "$REPO_DIR"
git -C "$REPO_DIR" commit --allow-empty -q -m "init"
git -C "$REPO_DIR" worktree add -q "$WORKTREE_DIR" 2>/dev/null

# --- Test 1: Outputs worktree path on stdout ---
output=$(run_hook "$WORKTREE_DIR" "test-wt")
assert_eq "outputs worktree path on stdout" "$WORKTREE_DIR" "$output"

# --- Test 2: Exits 1 when cwd is missing from input ---
set +e
echo '{}' | bash "$HOOK"
exit_code=$?
set -e
assert_exit "exits 1 when cwd is empty" "1" "$exit_code"

# --- Test 3: Does not copy when no root settings.local.json exists ---
run_hook "$WORKTREE_DIR" "test-wt" >/dev/null
DEST_DIR="${WORKTREE_DIR}/.claude"
dest="${DEST_DIR}/settings.local.json"
assert_eq "does not create settings.local.json when root has none" "false" "$([[ -f $dest ]] && echo true || echo false)"

# --- Test 4: Copies root settings.local.json to new worktree ---
ROOT_SETTINGS="${REPO_DIR}/.claude/settings.local.json"
mkdir -p "${REPO_DIR}/.claude"
echo '{"test": true}' >"$ROOT_SETTINGS"
run_hook "$WORKTREE_DIR" "test-wt" >/dev/null
assert_eq "copies settings.local.json to worktree" "true" "$([[ -f $dest ]] && echo true || echo false)"
copied_content=$(cat "$dest")
assert_eq "content matches root settings.local.json" '{"test": true}' "$copied_content"

# --- Test 5: Does not overwrite existing worktree settings ---
echo '{"existing": true}' >"$dest"
run_hook "$WORKTREE_DIR" "test-wt" >/dev/null
existing_content=$(cat "$dest")
assert_eq "does not overwrite existing settings.local.json" '{"existing": true}' "$existing_content"

# --- Test 6: Exits 0 for non-git directory ---
NON_GIT="${TMP_DIR}/nongit"
mkdir -p "$NON_GIT"
set +e
output=$(jq -nc --arg cwd "$NON_GIT" '{cwd: $cwd, name: "x"}' | bash "$HOOK")
exit_code=$?
set -e
assert_exit "exits 0 for non-git directory" "0" "$exit_code"
assert_eq "still outputs cwd for non-git directory" "$NON_GIT" "$output"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
