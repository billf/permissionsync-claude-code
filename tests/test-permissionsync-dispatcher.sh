#!/usr/bin/env bash
# test-permissionsync-dispatcher.sh — tests for permissionsync.sh dispatcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCHER="${SCRIPT_DIR}/../permissionsync.sh"

PASS=0
FAIL=0
TEST_NUM=0

echo "TAP version 13"

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

assert_exit_nonzero() {
	local desc="$1"
	shift
	TEST_NUM=$((TEST_NUM + 1))
	if ! "$@" >/dev/null 2>&1; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected non-zero exit from: $*"
		FAIL=$((FAIL + 1))
	fi
}

# Build a fake scripts directory so dispatcher delegates to our stubs
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INVOKED="${TMP_DIR}/invoked"
export INVOKED

# Create a stub factory: each stub records its name and args
make_stub() {
	local name="$1"
	local stub="${TMP_DIR}/${name}"
	cat >"$stub" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"$INVOKED"
EOF
	chmod +x "$stub"
}

make_stub "permissionsync-sync.sh"
make_stub "permissionsync-worktree-sync.sh"
make_stub "permissionsync-settings.sh"
make_stub "permissionsync-launch.sh"
make_stub "permissionsync-install.sh"

# Copy dispatcher alongside stubs (so SCRIPT_DIR finds them)
DISPATCHER_COPY="${TMP_DIR}/permissionsync.sh"
cp "$DISPATCHER" "$DISPATCHER_COPY"

run_dispatcher() {
	: >"$INVOKED"
	bash "$DISPATCHER_COPY" "$@"
}

# --- Test 1: No args exits non-zero ---
assert_exit_nonzero "no args exits non-zero" bash "$DISPATCHER_COPY"

# --- Test 2: Unknown subcommand exits non-zero ---
assert_exit_nonzero "unknown subcommand exits non-zero" bash "$DISPATCHER_COPY" bogus

# --- Test 3: help exits 0 ---
TEST_NUM=$((TEST_NUM + 1))
if bash "$DISPATCHER_COPY" --help >/dev/null 2>&1; then
	echo "ok ${TEST_NUM} - help exits 0"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - help exits 0"
	FAIL=$((FAIL + 1))
fi

# --- Test 4: sync delegates to permissionsync-sync.sh ---
run_dispatcher sync --apply
recorded=$(cat "$INVOKED")
assert_contains "sync delegates to permissionsync-sync.sh" "permissionsync-sync.sh" "$recorded"
assert_contains "sync passes --apply through" "--apply" "$recorded"

# --- Test 5: worktree delegates to permissionsync-worktree-sync.sh ---
run_dispatcher worktree --report
recorded=$(cat "$INVOKED")
assert_contains "worktree delegates to permissionsync-worktree-sync.sh" "permissionsync-worktree-sync.sh" "$recorded"
assert_contains "worktree passes --report through" "--report" "$recorded"

# --- Test 6: settings delegates to permissionsync-settings.sh ---
run_dispatcher settings --refine
recorded=$(cat "$INVOKED")
assert_contains "settings delegates to permissionsync-settings.sh" "permissionsync-settings.sh" "$recorded"
assert_contains "settings passes --refine through" "--refine" "$recorded"

# --- Test 7: launch delegates to permissionsync-launch.sh ---
run_dispatcher launch --dry-run my-feature
recorded=$(cat "$INVOKED")
assert_contains "launch delegates to permissionsync-launch.sh" "permissionsync-launch.sh" "$recorded"
assert_contains "launch passes worktree name through" "my-feature" "$recorded"

# --- Test 8: install with no mode calls permissionsync-install.sh with no args ---
run_dispatcher install
recorded=$(cat "$INVOKED")
assert_contains "install delegates to permissionsync-install.sh" "permissionsync-install.sh" "$recorded"

# --- Test 9: install --mode=auto translates to --auto ---
run_dispatcher install --mode=auto
recorded=$(cat "$INVOKED")
assert_contains "install --mode=auto passes --auto" "--auto" "$recorded"

# --- Test 10: install --mode=worktree translates to --worktree ---
run_dispatcher install --mode=worktree
recorded=$(cat "$INVOKED")
assert_contains "install --mode=worktree passes --worktree" "--worktree" "$recorded"

# --- Test 11: install --mode=log passes no mode arg ---
run_dispatcher install --mode=log
recorded=$(cat "$INVOKED")
# Should have called permissionsync-install.sh but without --auto or --worktree
assert_contains "install --mode=log calls permissionsync-install.sh" "permissionsync-install.sh" "$recorded"
TEST_NUM=$((TEST_NUM + 1))
if ! echo "$recorded" | grep -qF -- "--auto" && ! echo "$recorded" | grep -qF -- "--worktree"; then
	echo "ok ${TEST_NUM} - install --mode=log passes no mode flag"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - install --mode=log passes no mode flag"
	echo "#   recorded: '$recorded'"
	FAIL=$((FAIL + 1))
fi

# --- Test 12: status subcommand runs without error ---
TEST_NUM=$((TEST_NUM + 1))
if bash "$DISPATCHER_COPY" status >/dev/null 2>/dev/null; then
	echo "ok ${TEST_NUM} - status exits 0"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - status exits 0"
	FAIL=$((FAIL + 1))
fi

# --- Test 13: status output contains expected sections ---
output=$(bash "$DISPATCHER_COPY" status 2>/dev/null)
assert_contains "status shows permissionsync-cc header" "permissionsync-cc" "$output"
assert_contains "status shows Hooks section" "Hooks:" "$output"
assert_contains "status shows Settings section" "Settings" "$output"

# --- Tests 13b: status shows all 7 hook lines when fully installed ---
FAKE_HOME_FULL=$(mktemp -d)
mkdir -p "$FAKE_HOME_FULL/.claude"
HOOKS_DIR_FULL="$FAKE_HOME_FULL/.claude/hooks"
jq -nc \
	--arg pr "CLAUDE_PERMISSION_MODE=log ${HOOKS_DIR_FULL}/permissionsync-log-permission.sh" \
	--arg ptu "${HOOKS_DIR_FULL}/permissionsync-log-confirmed.sh" \
	--arg ptuf "${HOOKS_DIR_FULL}/permissionsync-log-hook-errors.sh" \
	--arg cc "${HOOKS_DIR_FULL}/permissionsync-watch-config.sh" \
	--arg se "${HOOKS_DIR_FULL}/permissionsync-sync-on-end.sh" \
	--arg ss "${HOOKS_DIR_FULL}/permissionsync-session-start.sh" \
	--arg wc "${HOOKS_DIR_FULL}/permissionsync-worktree-create.sh" \
	'{hooks:{
		PermissionRequest:[{matcher:"*",hooks:[{type:"command",command:$pr}]}],
		PostToolUse:[{matcher:"*",hooks:[{type:"command",command:$ptu}]}],
		PostToolUseFailure:[{matcher:"*",hooks:[{type:"command",command:$ptuf}]}],
		ConfigChange:[{matcher:"user_settings",hooks:[{type:"command",command:$cc}]}],
		SessionEnd:[{matcher:"*",hooks:[{type:"command",command:$se}]}],
		SessionStart:[{hooks:[{type:"command",command:$ss}]}],
		WorktreeCreate:[{hooks:[{type:"command",command:$wc}]}]
	}}' >"$FAKE_HOME_FULL/.claude/settings.json"
output_full=$(HOME="$FAKE_HOME_FULL" bash "$DISPATCHER_COPY" status 2>/dev/null)
assert_contains "full install: PermissionRequest installed" "PermissionRequest:" "$output_full"
assert_contains "full install: PostToolUse installed" "PostToolUse:" "$output_full"
assert_contains "full install: PostToolUseFailure installed" "PostToolUseFailure:" "$output_full"
assert_contains "full install: ConfigChange installed" "ConfigChange:" "$output_full"
assert_contains "full install: SessionEnd installed" "SessionEnd:" "$output_full"
assert_contains "full install: SessionStart installed" "SessionStart:" "$output_full"
assert_contains "full install: WorktreeCreate installed" "WorktreeCreate:" "$output_full"
assert_contains "full install: PostToolUse shows script name" "permissionsync-log-confirmed.sh" "$output_full"
assert_contains "full install: PostToolUseFailure shows script name" "permissionsync-log-hook-errors.sh" "$output_full"
assert_contains "full install: ConfigChange shows script name" "permissionsync-watch-config.sh" "$output_full"
assert_contains "full install: SessionEnd shows script name" "permissionsync-sync-on-end.sh" "$output_full"
assert_contains "full install: SessionStart shows script name" "permissionsync-session-start.sh" "$output_full"
assert_contains "full install: WorktreeCreate shows script name" "permissionsync-worktree-create.sh" "$output_full"
rm -rf "$FAKE_HOME_FULL"

# --- Tests 13c: partial install shows missing for absent hooks ---
FAKE_HOME_PARTIAL=$(mktemp -d)
mkdir -p "$FAKE_HOME_PARTIAL/.claude"
HOOKS_DIR_PARTIAL="$FAKE_HOME_PARTIAL/.claude/hooks"
jq -nc \
	--arg pr "CLAUDE_PERMISSION_MODE=log ${HOOKS_DIR_PARTIAL}/permissionsync-log-permission.sh" \
	'{hooks:{PermissionRequest:[{matcher:"*",hooks:[{type:"command",command:$pr}]}]}}' \
	>"$FAKE_HOME_PARTIAL/.claude/settings.json"
output_partial=$(HOME="$FAKE_HOME_PARTIAL" bash "$DISPATCHER_COPY" status 2>/dev/null)
assert_contains "partial install: PostToolUse shows missing" "PostToolUse:         missing" "$output_partial"
assert_contains "partial install: PostToolUseFailure shows missing" "PostToolUseFailure:  missing" "$output_partial"
assert_contains "partial install: ConfigChange shows missing" "ConfigChange:        missing" "$output_partial"
assert_contains "partial install: SessionEnd shows missing" "SessionEnd:          missing" "$output_partial"
assert_contains "partial install: SessionStart shows missing" "SessionStart:        missing" "$output_partial"
assert_contains "partial install: WorktreeCreate shows missing" "WorktreeCreate:      missing" "$output_partial"
rm -rf "$FAKE_HOME_PARTIAL"

# --- Test 14: legacy worktree mode detection (CLAUDE_PERMISSION_WORKTREE=1) ---
FAKE_HOME_WT=$(mktemp -d)
mkdir -p "$FAKE_HOME_WT/.claude"
jq -nc '{hooks:{PermissionRequest:[{matcher:"*",hooks:[{type:"command",command:"CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 /home/user/.claude/hooks/log-permission-auto.sh"}]}]}}' \
	>"$FAKE_HOME_WT/.claude/settings.json"
output_legacy_wt=$(HOME="$FAKE_HOME_WT" bash "$DISPATCHER_COPY" status 2>/dev/null)
assert_contains "legacy worktree mode shown in status" "worktree (legacy" "$output_legacy_wt"
rm -rf "$FAKE_HOME_WT"

# --- Test 15: legacy auto mode detection (CLAUDE_PERMISSION_AUTO=1 without worktree) ---
FAKE_HOME_AUTO=$(mktemp -d)
mkdir -p "$FAKE_HOME_AUTO/.claude"
jq -nc '{hooks:{PermissionRequest:[{matcher:"*",hooks:[{type:"command",command:"CLAUDE_PERMISSION_AUTO=1 /home/user/.claude/hooks/log-permission-auto.sh"}]}]}}' \
	>"$FAKE_HOME_AUTO/.claude/settings.json"
output_legacy_auto=$(HOME="$FAKE_HOME_AUTO" bash "$DISPATCHER_COPY" status 2>/dev/null)
assert_contains "legacy auto mode shown in status" "auto (legacy" "$output_legacy_auto"
rm -rf "$FAKE_HOME_AUTO"

# --- Test 16: legacy log mode detection (bare log-permission.sh, no env vars) ---
FAKE_HOME_LOG=$(mktemp -d)
mkdir -p "$FAKE_HOME_LOG/.claude"
jq -nc '{hooks:{PermissionRequest:[{matcher:"*",hooks:[{type:"command",command:"/home/user/.claude/hooks/log-permission.sh"}]}]}}' \
	>"$FAKE_HOME_LOG/.claude/settings.json"
output_legacy_log=$(HOME="$FAKE_HOME_LOG" bash "$DISPATCHER_COPY" status 2>/dev/null)
assert_contains "legacy log mode shown in status" "log (legacy" "$output_legacy_log"
rm -rf "$FAKE_HOME_LOG"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
