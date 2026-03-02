#!/usr/bin/env bash
# test-install.sh — unit tests for install.sh managed hook behavior
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="${SCRIPT_DIR}/../permissionsync-install.sh"

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

assert_contains() {
	local desc="$1" pattern="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if echo "$actual" | grep -qF -- "$pattern"; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected to contain: '${pattern}'"
		echo "#   actual:              '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

reset_home() {
	rm -rf "$TEST_HOME"
	TEST_HOME="$(mktemp -d)"
	expected_log="CLAUDE_PERMISSION_MODE=log $TEST_HOME/.claude/hooks/permissionsync-log-permission.sh"
	expected_auto="CLAUDE_PERMISSION_MODE=auto $TEST_HOME/.claude/hooks/permissionsync-log-permission.sh"
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
assert_eq "log mode uses CLAUDE_PERMISSION_MODE=log permissionsync-log-permission.sh" "$expected_log" "$cmd"

# --- Test 1b: log mode installs all 6 secondary hooks ---
ptu_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$TEST_HOME/.claude/settings.json")
assert_contains "log mode wires PostToolUse (log-confirmed)" "permissionsync-log-confirmed.sh" "$ptu_cmd"

ptuf_cmd=$(jq -r '.hooks.PostToolUseFailure[0].hooks[0].command' "$TEST_HOME/.claude/settings.json")
assert_contains "log mode wires PostToolUseFailure (log-hook-errors)" "permissionsync-log-hook-errors.sh" "$ptuf_cmd"

cc_cmd=$(jq -r '.hooks.ConfigChange[0].hooks[0].command' "$TEST_HOME/.claude/settings.json")
assert_contains "log mode wires ConfigChange (watch-config)" "permissionsync-watch-config.sh" "$cc_cmd"

se_cmd=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$TEST_HOME/.claude/settings.json")
assert_contains "log mode wires SessionEnd (sync-on-end)" "permissionsync-sync-on-end.sh" "$se_cmd"

ss_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$TEST_HOME/.claude/settings.json")
assert_contains "log mode wires SessionStart (session-start)" "permissionsync-session-start.sh" "$ss_cmd"

wc_cmd=$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$TEST_HOME/.claude/settings.json")
assert_contains "log mode wires WorktreeCreate (worktree-create)" "permissionsync-worktree-create.sh" "$wc_cmd"

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
assert_eq "auto->log updates command to MODE=log" "$expected_log" "$cmd"

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
expected_worktree="CLAUDE_PERMISSION_MODE=worktree $TEST_HOME/.claude/hooks/permissionsync-log-permission.sh"
run_install --worktree

cmd_wt=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "--worktree: hook command uses CLAUDE_PERMISSION_MODE=worktree" \
	"$expected_worktree" "$cmd_wt"

count_wt=$(jq '[.hooks.PermissionRequest[]?.hooks[]?.command] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "--worktree: installs one hook entry" "1" "$count_wt"

# --- Test 7: --worktree copies permissionsync-worktree-sync.sh ---
assert_eq "--worktree: copies permissionsync-worktree-sync.sh" "1" \
	"$(test -f "$TEST_HOME/.claude/hooks/permissionsync-worktree-sync.sh" && echo 1 || echo 0)"

# --- Test 8: Mode switch worktree->log keeps one entry ---
run_install

count_wt_log=$(jq '[.hooks.PermissionRequest[]?.hooks[]?.command] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "worktree->log keeps one hook entry" "1" "$count_wt_log"

cmd_wt_log=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "worktree->log updates command to MODE=log" "$expected_log" "$cmd_wt_log"

# --- Test 9: fresh install seeds baseline permissions ---
reset_home
run_install

allow_count=$(jq '.permissions.allow | length' "$TEST_HOME/.claude/settings.json")
TEST_NUM=$((TEST_NUM + 1))
if [[ $allow_count -gt 0 ]]; then
	echo "ok ${TEST_NUM} - fresh install seeds baseline rules (${allow_count} rules)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should seed baseline rules on fresh install, got: ${allow_count}"
	FAIL=$((FAIL + 1))
fi

# Verify a known rule is present
has_git=$(jq 'any(.permissions.allow[]; . == "Bash(git status *)")' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "baseline includes git status rule" "true" "$has_git"

has_bat=$(jq 'any(.permissions.allow[]; . == "Bash(bat *)")' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "baseline includes bat (always-safe) rule" "true" "$has_bat"

has_fd=$(jq 'any(.permissions.allow[]; . == "Bash(fd *)")' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "baseline excludes fd (not always-safe)" "false" "$has_fd"

# --- Test 10: re-install does NOT duplicate baseline rules ---
prev_count=$(jq '.permissions.allow | length' "$TEST_HOME/.claude/settings.json")
run_install --auto
new_count=$(jq '.permissions.allow | length' "$TEST_HOME/.claude/settings.json")
assert_eq "re-install does not add duplicate baseline rules" "$prev_count" "$new_count"

# --- Test 11: install with pre-existing allow rules skips seeding ---
reset_home
mkdir -p "$TEST_HOME/.claude"
echo '{"permissions": {"allow": ["Write"]}}' >"$TEST_HOME/.claude/settings.json"
run_install

allow_count_custom=$(jq '.permissions.allow | length' "$TEST_HOME/.claude/settings.json")
assert_eq "pre-existing allow rules: seeding skipped (still 1 rule)" "1" "$allow_count_custom"

# --- Test 12: backup is taken once before any modification ---
reset_home
mkdir -p "$TEST_HOME/.claude"
original_content='{"original": true}'
echo "$original_content" >"$TEST_HOME/.claude/settings.json"
run_install

bak_content=$(cat "$TEST_HOME/.claude/settings.json.bak")
assert_eq "backup reflects original pre-install content" "$original_content" "$bak_content"

# --- Test 13: re-running install does NOT overwrite existing backup ---
reset_home
mkdir -p "$TEST_HOME/.claude"
echo '{"original": true}' >"$TEST_HOME/.claude/settings.json"
run_install
# Create a sentinel in the backup to verify it is not overwritten on second run
echo '"sentinel"' >"$TEST_HOME/.claude/settings.json.bak"
run_install --auto
bak_after_rerun=$(cat "$TEST_HOME/.claude/settings.json.bak")
assert_eq "second install run does not overwrite existing backup" '"sentinel"' "$bak_after_rerun"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
