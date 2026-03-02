---
status: complete
priority: p2
issue_id: "017"
tags: [tests, fixtures, paths, portability]
dependencies: []
---

# Test fixtures use hardcoded /home/user/.claude/hooks/ paths

## Problem Statement

`tests/test-permissionsync-watch-config.sh` embeds hardcoded `/home/user/.claude/hooks/` in all four settings fixtures. If the guard logic ever becomes path-sensitive (exact match vs. prefix test), these fixtures would silently test wrong behavior on any system where `$HOME != /home/user`. The tests pass today only because the check uses `test("/.claude/hooks/")` as a substring match.

## Findings

**File:** `tests/test-permissionsync-watch-config.sh` lines 59, 62, 68, 76

```bash
"/home/user/.claude/hooks/log-permission-auto.sh"
"/home/user/.claude/hooks/log-confirmed.sh"
```

These are hardcoded to a specific user's home directory. All four fixture settings objects contain these literal paths. The test already creates `TMP_DIR` for isolation and correctly overrides `HOME="$TMP_DIR"` when invoking the script — but the fixture paths remain static.

**Risk if guard tightens:** If `permissionsync-watch-config.sh` is ever updated to check for an exact match against `$HOME/.claude/hooks/` (a reasonable security improvement), all test cases would produce false negatives on any system other than one with `$HOME=/home/user`.

**Correct fix:** Generate fixture paths dynamically using `$HOME`:

```bash
jq -nc \
  --arg perm_cmd "${HOME}/.claude/hooks/log-permission-auto.sh" \
  --arg post_cmd "${HOME}/.claude/hooks/log-confirmed.sh" \
  '{hooks: {
    PermissionRequest: [{matcher:"*",hooks:[{type:"command",command:$perm_cmd}]}],
    PostToolUse: [{matcher:"*",hooks:[{type:"command",command:$post_cmd}]}]
  }}' >"$GOOD_SETTINGS"
```

## Proposed Solutions

### Option A — Use $HOME for fixture paths (recommended)

Replace all 4 occurrences of `/home/user/.claude/hooks/` with `${HOME}/.claude/hooks/` in fixture-generating code.

**Pros:** Tests work on any system. Fixture paths match what the real installer would write.
**Cons:** Minimal — slightly more verbose fixture generation.
**Effort:** trivial
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] No hardcoded `/home/user/` in test fixture generation
- [ ] Fixture paths derived from `$HOME` at test run time
- [ ] Tests pass on systems where `$HOME != /home/user`

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Code simplicity review finding

**By:** Claude Code (code-simplicity-reviewer agent)

**Actions:**
- Found 4 occurrences of hardcoded /home/user path in test-permissionsync-watch-config.sh
- Verified tests pass today because guard uses substring match
- Identified fragility if guard ever tightens to exact path check

**Learnings:**
- Test fixtures should use dynamic paths matching the runtime environment
- Hardcoded paths in test fixtures create silent portability risks
