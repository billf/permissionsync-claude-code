---
status: ready
priority: p2
issue_id: "015"
tags: [watch-config, tests, coverage, tap]
dependencies: ["008"]
---

# test-watch-config missing coverage for 3 new hooks

## Problem Statement

`tests/test-permissionsync-watch-config.sh` fixture `GOOD_SETTINGS` only includes `PermissionRequest` and `PostToolUse`. There are no test cases asserting `HOOKS_INTACT=false` when `PostToolUseFailure`, `ConfigChange`, or `SessionEnd` are absent from `settings.json`. Once todo 008 (guard extended to all 5 hooks) is implemented, new tests are needed to verify the new coverage.

## Findings

**File:** `tests/test-permissionsync-watch-config.sh` lines 56–78

Current `GOOD_SETTINGS` fixture:
```bash
jq -nc '{
  "hooks": {
    "PermissionRequest": [{"matcher":"*","hooks":[{"type":"command","command":"/home/user/.claude/hooks/log-permission-auto.sh"}]}],
    "PostToolUse": [{"matcher":"*","hooks":[{"type":"command","command":"/home/user/.claude/hooks/log-confirmed.sh"}]}]
  }
}' >"$GOOD_SETTINGS"
```

Missing test coverage:
1. `GOOD_SETTINGS` with all 5 hooks → `HOOKS_INTACT=true`
2. Settings with `PostToolUseFailure` absent → `HOOKS_INTACT=false` + WARNING
3. Settings with `ConfigChange` absent → `HOOKS_INTACT=false` + WARNING
4. Settings with `SessionEnd` absent → `HOOKS_INTACT=false` + WARNING

Also: the hardcoded `/home/user/.claude/hooks/` path in fixtures should use `$HOME` or a dynamic value (see todo 017).

## Proposed Solutions

### Option A — Add 3 bad-settings fixtures + test cases (recommended)

```bash
# bad-settings: missing PostToolUseFailure
BAD_SETTINGS_PTF="${TMP_DIR}/settings-missing-ptf.json"
jq -nc '{hooks: {
  PermissionRequest: [{...}], PostToolUse: [{...}],
  ConfigChange: [{...}], SessionEnd: [{...}]
}}' >"$BAD_SETTINGS_PTF"

# Test: missing PostToolUseFailure → HOOKS_INTACT=false
result=$(HOME="$TMP_DIR" bash permissionsync-watch-config.sh <<<"$valid_input" 2>&1)
assert_eq "HOOKS_INTACT=false when PostToolUseFailure missing" "true" \
  "$(echo "$result" | grep -c WARNING)"
```

Repeat for ConfigChange and SessionEnd.

Also update `GOOD_SETTINGS` to include all 5 hooks.

**Effort:** medium
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] `GOOD_SETTINGS` fixture includes all 5 installed hooks
- [ ] Test: remove each of the 3 new hooks → `HOOKS_INTACT=false` + WARNING on stderr
- [ ] Existing tests still pass
- [ ] Fixture paths use `$HOME` or `$TMP_DIR` rather than hardcoded `/home/user/...`

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready
- Blocked by Issue #008 (guard must be extended first)

### 2026-02-28 — Architecture review + pattern review finding

**By:** Claude Code (architecture-strategist + pattern-recognition-specialist agents)

**Actions:**
- Identified GOOD_SETTINGS fixture only populates 2 of 5 hooks
- Confirmed no test cases for absence of new hooks
- Noted dependency on 008 (guard must be extended first)

**Learnings:**
- Test fixtures must stay in sync with the guard logic they're testing
- Missing test cases make guard gaps invisible to CI
