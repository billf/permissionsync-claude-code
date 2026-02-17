#!/usr/bin/env bash
# test-worktree-discovery.sh — tests for worktree discovery functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORIG_DIR="$(pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
trap 'cd "$ORIG_DIR"; rm -rf "$TMP_DIR"' EXIT

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

assert_rc() {
	local desc="$1" expected="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if [[ $expected == "$actual" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected rc: '${expected}'"
		echo "#   actual rc:   '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# ============================================================
# Setup: Create a git repo with worktrees
# ============================================================

# Resolve TMP_DIR to canonical path (macOS /var → /private/var)
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"

REPO_MAIN="${TMP_DIR}/repo-main"
mkdir -p "$REPO_MAIN"
git -C "$REPO_MAIN" init -b main >/dev/null 2>&1
git -C "$REPO_MAIN" config user.email "test@test.com"
git -C "$REPO_MAIN" config user.name "Test"
echo "hello" >"$REPO_MAIN/file.txt"
git -C "$REPO_MAIN" add file.txt
git -C "$REPO_MAIN" commit -m "init" >/dev/null 2>&1

# Create worktrees
REPO_WT1="${TMP_DIR}/repo-wt1"
git -C "$REPO_MAIN" worktree add "$REPO_WT1" -b wt1 >/dev/null 2>&1

REPO_WT2="${TMP_DIR}/repo-wt2"
git -C "$REPO_MAIN" worktree add "$REPO_WT2" -b wt2 >/dev/null 2>&1

# A standalone repo (no worktrees)
REPO_STANDALONE="${TMP_DIR}/repo-standalone"
mkdir -p "$REPO_STANDALONE"
git -C "$REPO_STANDALONE" init -b main >/dev/null 2>&1
git -C "$REPO_STANDALONE" config user.email "test@test.com"
git -C "$REPO_STANDALONE" config user.name "Test"
echo "alone" >"$REPO_STANDALONE/file.txt"
git -C "$REPO_STANDALONE" add file.txt
git -C "$REPO_STANDALONE" commit -m "init" >/dev/null 2>&1

# Not a git dir
NO_GIT="${TMP_DIR}/not-a-repo"
mkdir -p "$NO_GIT"

# Source the library from the project root
source "${SCRIPT_DIR}/../permissionsync-lib.sh"

# ============================================================
# is_in_worktree tests
# ============================================================

# Test: not in a git repo
rc=0
(cd "$NO_GIT" && is_in_worktree) || rc=$?
assert_rc "is_in_worktree: not a git repo returns 1" "1" "$rc"

# Test: standalone repo (no worktrees) returns 1
rc=0
(cd "$REPO_STANDALONE" && is_in_worktree) || rc=$?
assert_rc "is_in_worktree: standalone repo returns 1" "1" "$rc"

# Test: main worktree with siblings returns 0
rc=0
(cd "$REPO_MAIN" && is_in_worktree) || rc=$?
assert_rc "is_in_worktree: main worktree with siblings returns 0" "0" "$rc"

# Test: linked worktree returns 0
rc=0
(cd "$REPO_WT1" && is_in_worktree) || rc=$?
assert_rc "is_in_worktree: linked worktree returns 0" "0" "$rc"

# ============================================================
# discover_worktrees tests
# ============================================================

# Test: discover from main, excluding current — should find wt1 and wt2
cd "$REPO_MAIN"
discover_worktrees 1
assert_eq "discover_worktrees(1) from main: count" "2" "$WORKTREE_COUNT"

# Test: discover from main, including current — should find all 3
discover_worktrees 0
assert_eq "discover_worktrees(0) from main: count" "3" "$WORKTREE_COUNT"

# Test: discover from linked wt1, excluding current — should find main and wt2
cd "$REPO_WT1"
discover_worktrees 1
assert_eq "discover_worktrees(1) from wt1: count" "2" "$WORKTREE_COUNT"

# Verify specific paths are found
found_main=0
found_wt2=0
for ((i = 0; i < WORKTREE_COUNT; i++)); do
	case "${WORKTREE_PATHS[$i]}" in
	"$REPO_MAIN") found_main=1 ;;
	"$REPO_WT2") found_wt2=1 ;;
	esac
done
assert_eq "discover_worktrees(1) from wt1: includes main" "1" "$found_main"
assert_eq "discover_worktrees(1) from wt1: includes wt2" "1" "$found_wt2"

# Test: discover from standalone — no siblings
cd "$REPO_STANDALONE"
discover_worktrees 1
assert_eq "discover_worktrees(1) from standalone: count" "0" "$WORKTREE_COUNT"

# Test: discover from non-git dir fails
rc=0
cd "$NO_GIT"
discover_worktrees 1 || rc=$?
assert_rc "discover_worktrees from non-git dir returns 1" "1" "$rc"

# ============================================================
# read_sibling_rules tests
# ============================================================

# Test: no settings files → returns 1
cd "$REPO_MAIN"
rc=0
read_sibling_rules || rc=$?
assert_rc "read_sibling_rules: no settings files returns 1" "1" "$rc"

# Add settings.local.json to wt1
mkdir -p "$REPO_WT1/.claude"
cat >"$REPO_WT1/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git *)", "Bash(cargo check *)"]
  }
}
EOF

# Test: one sibling has rules — from main should find them
cd "$REPO_MAIN"
read_sibling_rules
assert_eq "read_sibling_rules: finds rules from wt1" "2" "$SIBLING_RULE_COUNT"

# Add settings.local.json to wt2 with overlapping rules
mkdir -p "$REPO_WT2/.claude"
cat >"$REPO_WT2/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git *)", "Bash(npm list *)"]
  }
}
EOF

# Test: deduplication across siblings
cd "$REPO_MAIN"
read_sibling_rules
assert_eq "read_sibling_rules: deduplicates across siblings" "3" "$SIBLING_RULE_COUNT"

# Verify specific rules
has_git=0
has_cargo=0
has_npm=0
while IFS= read -r rule; do
	case "$rule" in
	"Bash(git *)") has_git=1 ;;
	"Bash(cargo check *)") has_cargo=1 ;;
	"Bash(npm list *)") has_npm=1 ;;
	esac
done <<<"$SIBLING_RULES"
assert_eq "read_sibling_rules: has git rule" "1" "$has_git"
assert_eq "read_sibling_rules: has cargo rule" "1" "$has_cargo"
assert_eq "read_sibling_rules: has npm rule" "1" "$has_npm"

# Test: from wt1, should find rules from main and wt2 (not self)
# main has no settings, so should only see wt2 rules
cd "$REPO_WT1"
read_sibling_rules
assert_eq "read_sibling_rules from wt1: finds wt2 rules only" "2" "$SIBLING_RULE_COUNT"

# Test: from standalone, returns 1
cd "$REPO_STANDALONE"
rc=0
read_sibling_rules || rc=$?
assert_rc "read_sibling_rules: standalone repo returns 1" "1" "$rc"

# Test: malformed settings.local.json is skipped gracefully
mkdir -p "$REPO_MAIN/.claude"
echo "NOT JSON" >"$REPO_MAIN/.claude/settings.local.json"
cd "$REPO_WT1"
read_sibling_rules
# Should still find wt2 rules despite main having bad JSON
assert_eq "read_sibling_rules: skips malformed JSON" "2" "$SIBLING_RULE_COUNT"

# Clean up the malformed file
rm -f "$REPO_MAIN/.claude/settings.local.json"

cd "$ORIG_DIR"

echo ""
echo "1..${TEST_NUM}"
echo "# pass ${PASS}/${TEST_NUM}"
if [[ $FAIL -gt 0 ]]; then
	echo "# FAIL ${FAIL}"
	exit 1
fi
