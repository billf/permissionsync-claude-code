#!/usr/bin/env bash
# test-install.sh — unit tests for install.sh managed hook behavior
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="${SCRIPT_DIR}/../install.sh"

PASS=0
FAIL=0
TEST_NUM=0

TEST_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

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

reset_home() {
	rm -rf "$TEST_HOME"
	TEST_HOME="$(mktemp -d)"
	expected_log="$TEST_HOME/.claude/hooks/log-permission.sh"
	expected_auto="CLAUDE_PERMISSION_AUTO=1 $TEST_HOME/.claude/hooks/log-permission-auto.sh"
}

run_install() {
	local mode="${1:-}"
	if [[ -n $mode ]]; then
		HOME="$TEST_HOME" bash "$INSTALL" "$mode" >/dev/null
	else
		HOME="$TEST_HOME" bash "$INSTALL" >/dev/null
	fi
}

echo "TAP version 13"

# --- Test 1: log mode creates one managed entry ---
reset_home
run_install

count=$(jq '[.hooks.PermissionRequest[]?.hooks[]?.command] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log mode installs one hook entry" "1" "$count"

cmd=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log mode uses log-permission.sh" "$expected_log" "$cmd"

# --- Test 2: mode switch log->auto keeps one entry and updates command ---
run_install --auto

count=$(jq '[.hooks.PermissionRequest[]?.hooks[]?.command] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log->auto keeps one hook entry" "1" "$count"

cmd=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log->auto updates command" "$expected_auto" "$cmd"

# --- Test 3: mode switch auto->log keeps one entry and updates command ---
run_install

count=$(jq '[.hooks.PermissionRequest[]?.hooks[]?.command] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "auto->log keeps one hook entry" "1" "$count"

cmd=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "auto->log updates command" "$expected_log" "$cmd"

# --- Test 4: collapses pre-existing managed duplicates and keeps non-managed ---
reset_home
mkdir -p "$TEST_HOME/.claude"
cat >"$TEST_HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "$expected_log"}]
      },
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "$expected_auto"}]
      },
      {
        "matcher": "Write",
        "hooks": [{"type": "command", "command": "/tmp/custom-hook.sh"}]
      }
    ]
  }
}
EOF
run_install

managed_count=$(jq --arg log "$expected_log" --arg auto "$expected_auto" \
	'[.hooks.PermissionRequest[]?.hooks[]?.command | select(. == $log or . == $auto)] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "managed duplicates collapse to one entry" "1" "$managed_count"

custom_count=$(jq \
	'[.hooks.PermissionRequest[]?.hooks[]?.command | select(. == "/tmp/custom-hook.sh")] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "non-managed entry remains" "1" "$custom_count"

# --- Test 5: preserves non-managed hooks in mixed entries ---
reset_home
mkdir -p "$TEST_HOME/.claude"
cat >"$TEST_HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$expected_log"},
          {"type": "command", "command": "/tmp/custom-mixed-hook.sh"}
        ]
      }
    ]
  }
}
EOF
run_install --auto

managed_count=$(jq --arg log "$expected_log" --arg auto "$expected_auto" \
	'[.hooks.PermissionRequest[]?.hooks[]?.command | select(. == $log or . == $auto)] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "mixed entry still has one managed hook" "1" "$managed_count"

managed_cmd=$(jq -r --arg log "$expected_log" --arg auto "$expected_auto" \
	'[.hooks.PermissionRequest[]?.hooks[]?.command | select(. == $log or . == $auto)][0]' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "mixed entry updates managed hook command" "$expected_auto" "$managed_cmd"

custom_mixed_count=$(jq \
	'[.hooks.PermissionRequest[]?.hooks[]?.command | select(. == "/tmp/custom-mixed-hook.sh")] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "mixed entry keeps custom hook" "1" "$custom_mixed_count"

# --- Test 6: --worktree mode sets correct hook command ---
reset_home
expected_worktree="CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 $TEST_HOME/.claude/hooks/log-permission-auto.sh"
run_install --worktree

cmd_wt=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "--worktree: hook command includes CLAUDE_PERMISSION_WORKTREE=1" \
	"$expected_worktree" "$cmd_wt"

count_wt=$(jq '[.hooks.PermissionRequest[]?.hooks[]?.command] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "--worktree: installs one hook entry" "1" "$count_wt"

# --- Test 7: --worktree copies worktree-sync.sh ---
assert_eq "--worktree: copies worktree-sync.sh" "1" \
	"$(test -f "$TEST_HOME/.claude/hooks/worktree-sync.sh" && echo 1 || echo 0)"

# --- Test 8: Mode switch worktree->log keeps one entry ---
run_install

count_wt_log=$(jq '[.hooks.PermissionRequest[]?.hooks[]?.command] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "worktree->log keeps one hook entry" "1" "$count_wt_log"

cmd_wt_log=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "worktree->log updates command" "$expected_log" "$cmd_wt_log"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
