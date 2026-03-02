---
status: complete
priority: p2
issue_id: "011"
tags: [watch-config, config, env-var, changes-log, convention]
dependencies: []
---

# CHANGES_LOG hardcoded — doesn't follow CLAUDE_PERMISSION_LOG directory convention

## Problem Statement

`permissionsync-watch-config.sh` hardcodes `CHANGES_LOG="$HOME/.claude/config-changes.jsonl"`. Every other hook script in the project derives its log directory from `CLAUDE_PERMISSION_LOG`, placing sibling logs alongside the base log. Overriding `CLAUDE_PERMISSION_LOG` splits the audit trail: all other logs redirect, but `config-changes.jsonl` stays in `$HOME/.claude/`.

## Findings

**File:** `permissionsync-watch-config.sh` line 12
```bash
CHANGES_LOG="$HOME/.claude/config-changes.jsonl"
```

**Established convention** (from sibling scripts):

`permissionsync-log-hook-errors.sh` lines 8–9:
```bash
BASE_LOG="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
ERRORS_LOG="$(dirname "$BASE_LOG")/hook-errors.jsonl"
```

`log-confirmed.sh` lines 19–20:
```bash
BASE_LOG="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
CONFIRMED_LOG="$(dirname "$BASE_LOG")/confirmed-approvals.jsonl"
```

Both sibling scripts derive the directory from `CLAUDE_PERMISSION_LOG` and place their log file alongside it. `watch-config.sh` hardcodes `$HOME/.claude/` directly.

**Test workaround:** The test overrides `HOME` (`HOME="$TMP_DIR" bash ...`) rather than `CLAUDE_PERMISSION_LOG`, which works but is not testing the environment variable path.

## Proposed Solutions

### Option A — Follow the established convention (recommended)

Replace line 12 with:
```bash
BASE_LOG="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
CHANGES_LOG="$(dirname "$BASE_LOG")/config-changes.jsonl"
```

**Pros:** Consistent with every other log-writing script. `CLAUDE_PERMISSION_LOG` override correctly redirects all logs together.
**Cons:** Slightly more verbose.
**Effort:** trivial
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] `CHANGES_LOG` is derived from `CLAUDE_PERMISSION_LOG` directory (or default)
- [ ] Overriding `CLAUDE_PERMISSION_LOG` causes `config-changes.jsonl` to land in the same directory as other logs
- [ ] Tests verify `CHANGES_LOG` path when `CLAUDE_PERMISSION_LOG` is set

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Pattern review finding

**By:** Claude Code (pattern-recognition-specialist agent)

**Actions:**
- Compared log path derivation across all hook scripts
- Identified watch-config.sh as the only script not following the convention
- Noted test uses HOME override as a workaround

**Learnings:**
- Shared conventions for log directory derivation are critical for unified log management
- Tests that work around a missing convention mask the underlying inconsistency
