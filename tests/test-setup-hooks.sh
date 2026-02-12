#!/usr/bin/env bash
# test-setup-hooks.sh — unit tests for setup-hooks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_HOOKS="${SCRIPT_DIR}/../setup-hooks.sh"

PASS=0
FAIL=0
TEST_NUM=0

# Use a temp HOME so we never touch the real ~/.claude/
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

assert_file_exists() {
	local desc="$1" path="$2"
	TEST_NUM=$((TEST_NUM + 1))
	if [[ -f $path ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   file not found: ${path}"
		FAIL=$((FAIL + 1))
	fi
}

run_setup() {
	local mode="${1:-log}"
	HOME="$TEST_HOME" PERMISSIONSYNC_SHARE_DIR="${SCRIPT_DIR}/.." \
		bash "$SETUP_HOOKS" "$mode" 2>&1
}

echo "TAP version 13"

# --- Test 1: First run creates all hook files ---
reset_home() {
	rm -rf "$TEST_HOME"
	TEST_HOME="$(mktemp -d)"
	expected_log="$TEST_HOME/.claude/hooks/log-permission.sh"
	expected_auto="CLAUDE_PERMISSION_AUTO=1 $TEST_HOME/.claude/hooks/log-permission-auto.sh"
}

reset_home
output=$(run_setup log)

assert_file_exists "log mode: creates permissionsync-config.sh" \
	"$TEST_HOME/.claude/hooks/permissionsync-config.sh"

assert_file_exists "log mode: creates permissionsync-lib.sh" \
	"$TEST_HOME/.claude/hooks/permissionsync-lib.sh"

assert_file_exists "log mode: creates log-permission.sh" \
	"$TEST_HOME/.claude/hooks/log-permission.sh"

assert_file_exists "log mode: creates log-permission-auto.sh" \
	"$TEST_HOME/.claude/hooks/log-permission-auto.sh"

assert_file_exists "log mode: creates sync-permissions.sh" \
	"$TEST_HOME/.claude/hooks/sync-permissions.sh"

# --- Test 2: settings.json has PermissionRequest hook ---
assert_file_exists "log mode: creates settings.json" \
	"$TEST_HOME/.claude/settings.json"

hook_cmd=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log mode: hook command points to log-permission.sh" \
	"$expected_log" "$hook_cmd"

matcher=$(jq -r '.hooks.PermissionRequest[0].matcher' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log mode: matcher is wildcard" "*" "$matcher"

# --- Test 3: First run reports changes ---
assert_eq "first run reports installation" \
	"permissionsync-cc: hooks installed (log mode)" "$output"

# --- Test 4: Second run is a no-op (idempotent) ---
output2=$(run_setup log)
assert_eq "second run is silent (no-op)" "" "$output2"

# --- Test 5: Auto mode sets correct hook command ---
reset_home
run_setup auto >/dev/null

hook_cmd_auto=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "auto mode: hook command includes CLAUDE_PERMISSION_AUTO=1" \
	"$expected_auto" "$hook_cmd_auto"

# --- Test 6: Does not duplicate hook entry on repeated runs ---
reset_home
run_setup log >/dev/null
run_setup log >/dev/null

hook_count=$(jq '[.hooks.PermissionRequest[].hooks[]] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "no duplicate hook entries after repeated runs" "1" "$hook_count"

# --- Test 7: Switching modes updates the single managed entry (log -> auto) ---
reset_home
run_setup log >/dev/null
switch_out=$(run_setup auto)

hook_count_switch=$(jq '[.hooks.PermissionRequest[].hooks[]] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log->auto keeps one hook entry" "1" "$hook_count_switch"

hook_cmd_switch=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "log->auto updates hook command" "$expected_auto" "$hook_cmd_switch"

assert_eq "log->auto reports installation" \
	"permissionsync-cc: hooks installed (auto mode)" "$switch_out"

# --- Test 8: Switching modes updates the single managed entry (auto -> log) ---
reset_home
run_setup auto >/dev/null
switch_back_out=$(run_setup log)

hook_count_switch_back=$(jq '[.hooks.PermissionRequest[].hooks[]] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "auto->log keeps one hook entry" "1" "$hook_count_switch_back"

hook_cmd_switch_back=$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "auto->log updates hook command" "$expected_log" "$hook_cmd_switch_back"

assert_eq "auto->log reports installation" \
	"permissionsync-cc: hooks installed (log mode)" "$switch_back_out"

# --- Test 9: Preserves existing settings.json content ---
reset_home
mkdir -p "$TEST_HOME/.claude"
echo '{"permissions":{"allow":["Bash(git *)"]}}' >"$TEST_HOME/.claude/settings.json"
run_setup log >/dev/null

existing_perm=$(jq -r '.permissions.allow[0]' "$TEST_HOME/.claude/settings.json")
assert_eq "preserves existing settings content" "Bash(git *)" "$existing_perm"

has_hook=$(jq '.hooks.PermissionRequest | length' "$TEST_HOME/.claude/settings.json")
assert_eq "adds hook alongside existing settings" "1" "$has_hook"

# --- Test 10: Collapses pre-existing managed duplicates, keeps non-managed ---
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
run_setup log >/dev/null

managed_count=$(jq --arg log "$expected_log" --arg auto "$expected_auto" \
	'[.hooks.PermissionRequest[]?.hooks[]?.command | select(. == $log or . == $auto)] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "managed duplicates collapse to one entry" "1" "$managed_count"

custom_count=$(jq \
	'[.hooks.PermissionRequest[]?.hooks[]?.command | select(. == "/tmp/custom-hook.sh")] | length' \
	"$TEST_HOME/.claude/settings.json")
assert_eq "non-managed hook entry is preserved" "1" "$custom_count"

# --- Test 11: Creates backup on first settings.json modification ---
reset_home
mkdir -p "$TEST_HOME/.claude"
echo '{}' >"$TEST_HOME/.claude/settings.json"
run_setup log >/dev/null

assert_file_exists "creates settings.json.bak" \
	"$TEST_HOME/.claude/settings.json.bak"

# --- Summary ---
echo ""
echo "1..${TEST_NUM}"
echo "# pass ${PASS}/${TEST_NUM}"
if [[ $FAIL -gt 0 ]]; then
	echo "# FAIL ${FAIL}"
	exit 1
fi
