---
status: complete
priority: p2
issue_id: "013"
tags: [watch-config, security, file-path, config-change, validation]
dependencies: []
---

# watch-config uses file_path from hook stdin to select settings file without validation

## Problem Statement

`permissionsync-watch-config.sh` extracts `FILE_PATH` from the `ConfigChange` hook's stdin payload via `@sh` eval, then uses it as the path to inspect for hook integrity. If Claude Code sends a `file_path` pointing to an arbitrary file (crafted JSON, `/dev/stdin`, or a symlink), the guard will inspect the wrong file and may emit false `HOOKS_INTACT=false` warnings or miss real hook removal.

## Findings

**File:** `permissionsync-watch-config.sh` lines 6 and 11

```bash
eval "$(jq -r '@sh "SOURCE=\(.source // "") FILE_PATH=\(.file_path // "") SESSION_ID=\(.session_id // "") CWD=\(.cwd // "")"' <<<"$INPUT")"

SETTINGS_PATH="${FILE_PATH:-$HOME/.claude/settings.json}"
```

**`@sh` injection assessment:** The eval is injection-safe — `@sh` correctly wraps all values in single quotes. A value like `'; rm -rf /` becomes `''\''; rm -rf /'` — no execution.

**The actual risk:** `FILE_PATH` is then used as the path that jq inspects (line 20–21) to determine if hooks are intact:
```bash
has_permreq=$(jq -r '...' "$SETTINGS_PATH" 2>/dev/null || echo 0)
```

If `FILE_PATH` points to a crafted JSON file at a controlled path, the guard will analyze the wrong file. The consequence is limited to false warnings — the script never *writes* to `$SETTINGS_PATH`. However, the hook's purpose is to inspect the *real* `settings.json`, not whatever Claude Code happens to pass.

**Recommendation from security agent:** Ignore `file_path` for the guard logic entirely. Use it only for logging. Always inspect the known-safe path.

## Proposed Solutions

### Option A — Always use the known-safe settings path (recommended)

Remove `FILE_PATH` from determining `SETTINGS_PATH`:
```bash
SETTINGS_PATH="$HOME/.claude/settings.json"
```

Keep `FILE_PATH` available for the log output (so the audit entry records what Claude was changing).

**Pros:** Guard always inspects the real settings file regardless of hook payload.
**Cons:** Doesn't follow config changes to non-default settings paths (if Claude ever supports custom paths).
**Effort:** trivial
**Risk:** low

### Option B — Validate FILE_PATH is the expected settings file before using

```bash
EXPECTED_SETTINGS="$HOME/.claude/settings.json"
SETTINGS_PATH="$EXPECTED_SETTINGS"  # always
# Warn if FILE_PATH differs from expected
if [[ -n "$FILE_PATH" && "$FILE_PATH" != "$EXPECTED_SETTINGS" ]]; then
    echo "WARNING: ConfigChange fired for unexpected file: $FILE_PATH" >&2
fi
```

**Pros:** Logs unexpected paths; still safe.
**Cons:** More code for a rare condition.
**Effort:** small
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] Guard logic always inspects `$HOME/.claude/settings.json`, not a stdin-provided path
- [ ] `FILE_PATH` from stdin is still captured and logged in the JSONL output for audit purposes
- [ ] Test: hook with `file_path=/tmp/crafted.json` still inspects real settings path

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Security audit finding

**By:** Claude Code (security-sentinel agent)

**Actions:**
- Verified @sh eval is injection-safe
- Identified SETTINGS_PATH derived from hook stdin rather than hardcoded to expected path
- Confirmed consequence is limited to false warnings (no write path)

**Learnings:**
- Even when injection is safe, using untrusted input to select which file to inspect is a trust boundary violation
- The logging use of FILE_PATH is legitimate; the guard use is not
