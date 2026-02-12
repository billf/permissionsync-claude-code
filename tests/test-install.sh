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

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
