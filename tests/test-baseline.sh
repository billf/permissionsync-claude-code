#!/usr/bin/env bash
# test-baseline.sh — tests for generate-base-settings.sh output validation
#
# These tests verify the generated base-settings.json (from nix build output)
# or can run with a provided path. They validate the security invariants:
#   - No blocklisted binaries (bash, python, etc.)
#   - No deprecated colon format
#   - No gh repo clone (write operation)
#   - Expected structure with allow + deny arrays
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/permissionsync-lib.sh
source "${SCRIPT_DIR}/../lib/permissionsync-lib.sh"

PASS=0
FAIL=0
TEST_NUM=0

# Locate base-settings.json — check nix build result, then share dir
BASE_SETTINGS="${1:-}"
if [[ -z $BASE_SETTINGS ]]; then
	for candidate in \
		"${SCRIPT_DIR}/../result/share/permissionsync-cc/base-settings.json" \
		"${PERMISSIONSYNC_SHARE_DIR:-}/base-settings.json" \
		"${SCRIPT_DIR}/../base-settings.json"; do
		if [[ -f $candidate ]]; then
			BASE_SETTINGS="$candidate"
			break
		fi
	done
fi

if [[ -z $BASE_SETTINGS ]] || [[ ! -f $BASE_SETTINGS ]]; then
	echo "Bail out! base-settings.json not found (run nix build first)"
	exit 1
fi

echo "TAP version 13"
echo "# Testing: $BASE_SETTINGS"

# --- Structure tests ---
TEST_NUM=$((TEST_NUM + 1))
if jq -e '.permissions.allow | type == "array"' "$BASE_SETTINGS" >/dev/null 2>&1; then
	echo "ok ${TEST_NUM} - has permissions.allow array"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should have permissions.allow array"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if jq -e '.permissions.deny | type == "array"' "$BASE_SETTINGS" >/dev/null 2>&1; then
	echo "ok ${TEST_NUM} - has permissions.deny array"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should have permissions.deny array"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
ALLOW_COUNT=$(jq '.permissions.allow | length' "$BASE_SETTINGS")
if [[ $ALLOW_COUNT -gt 0 ]]; then
	echo "ok ${TEST_NUM} - has ${ALLOW_COUNT} allow rules"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should have at least one allow rule"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
DENY_COUNT=$(jq '.permissions.deny | length' "$BASE_SETTINGS")
if [[ $DENY_COUNT -gt 0 ]]; then
	echo "ok ${TEST_NUM} - has ${DENY_COUNT} deny rules"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should have at least one deny rule"
	FAIL=$((FAIL + 1))
fi

# --- Security: no deprecated colon format ---
TEST_NUM=$((TEST_NUM + 1))
if ! jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -qF ':*)'; then
	echo "ok ${TEST_NUM} - no deprecated colon format in allow rules"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - found deprecated colon format"
	jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep ':*)' | head -3
	FAIL=$((FAIL + 1))
fi

# --- Security: no blocklisted binaries ---
TEST_NUM=$((TEST_NUM + 1))
HAS_BLOCKLISTED=0
while IFS= read -r rule; do
	if [[ $rule =~ ^Bash\(([^\ \)]+) ]]; then
		bin="${BASH_REMATCH[1]}"
		if is_blocklisted_binary "$bin"; then
			echo "#   blocklisted: $rule"
			HAS_BLOCKLISTED=1
		fi
	fi
done < <(jq -r '.permissions.allow[]' "$BASE_SETTINGS")
if [[ $HAS_BLOCKLISTED -eq 0 ]]; then
	echo "ok ${TEST_NUM} - no blocklisted binaries in allow rules"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - found blocklisted binaries"
	FAIL=$((FAIL + 1))
fi

# --- Security: no find * (bash stack excluded) ---
TEST_NUM=$((TEST_NUM + 1))
if ! jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -qF 'Bash(find '; then
	echo "ok ${TEST_NUM} - no find rules (bash stack excluded)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - found find rule (bash stack should be excluded)"
	FAIL=$((FAIL + 1))
fi

# --- Security: no cat * (bash stack excluded) ---
TEST_NUM=$((TEST_NUM + 1))
if ! jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -qF 'Bash(cat '; then
	echo "ok ${TEST_NUM} - no cat rules (bash stack excluded)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - found cat rule (bash stack should be excluded)"
	FAIL=$((FAIL + 1))
fi

# --- Security: no gh repo clone ---
TEST_NUM=$((TEST_NUM + 1))
if ! jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -qF 'gh repo clone'; then
	echo "ok ${TEST_NUM} - no gh repo clone (write operation excluded)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - found gh repo clone (should be excluded)"
	FAIL=$((FAIL + 1))
fi

# --- Content: expected rules present ---
TEST_NUM=$((TEST_NUM + 1))
if jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -qF 'Bash(git status *)'; then
	echo "ok ${TEST_NUM} - contains git status rule"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should contain git status rule"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -qF 'Bash(gh pr list *)'; then
	echo "ok ${TEST_NUM} - contains gh pr list rule"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should contain gh pr list rule"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -qF 'Bash(gh search *)'; then
	echo "ok ${TEST_NUM} - contains gh search rule"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should contain gh search rule"
	FAIL=$((FAIL + 1))
fi

# --- Content: deny rules ---
TEST_NUM=$((TEST_NUM + 1))
if jq -r '.permissions.deny[]' "$BASE_SETTINGS" | grep -qF 'Read(~/.gitconfig)'; then
	echo "ok ${TEST_NUM} - deny: Read(~/.gitconfig)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should deny Read(~/.gitconfig)"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if jq -r '.permissions.deny[]' "$BASE_SETTINGS" | grep -qF 'Read(~/.config/gh/**)'; then
	echo "ok ${TEST_NUM} - deny: Read(~/.config/gh/**)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - should deny Read(~/.config/gh/**)"
	FAIL=$((FAIL + 1))
fi

# --- All rules use space format ---
TEST_NUM=$((TEST_NUM + 1))
SPACE_FORMAT_COUNT=$(jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -c ' \*)$' || true)
TOTAL_BASH_RULES=$(jq -r '.permissions.allow[]' "$BASE_SETTINGS" | grep -c '^Bash(' || true)
if [[ $SPACE_FORMAT_COUNT -eq $TOTAL_BASH_RULES ]]; then
	echo "ok ${TEST_NUM} - all ${TOTAL_BASH_RULES} Bash rules use space format"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - ${SPACE_FORMAT_COUNT}/${TOTAL_BASH_RULES} use space format"
	FAIL=$((FAIL + 1))
fi

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
