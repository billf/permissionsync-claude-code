---
status: complete
priority: p2
issue_id: "002"
tags: [dx, worktree, launcher]
dependencies: []
---

# permissionsync-launch wrapper script

## Problem Statement

Launching Claude in a worktree with merged permissions requires:
```bash
claude -w feature-x --settings <(~/.claude/hooks/merged-settings.sh --refine)
```
This is a 60+ character incantation that's hard to type and remember. There's no
first-class command that encapsulates the recommended worktree launch workflow.

## Findings

`merged-settings.sh` already handles merging global + sibling worktree settings.
The missing piece is a thin wrapper that:
- Accepts a worktree name (or uses current branch)
- Calls `claude -w <name> --settings <(merged-settings.sh [flags])`
- Exposes common flags as readable options

Use `git rev-parse --git-common-dir` to find the common worktree root when
discovering siblings (already used in `is_in_worktree()`).

## Proposed Solutions

### Option A — Standalone `permissionsync-launch` script (Recommended)
```bash
permissionsync-launch feature-x          # basic worktree launch
permissionsync-launch --log feature-x    # include --from-log
permissionsync-launch --global-only fx   # skip sibling discovery
permissionsync-launch                    # use current branch name
```
Installed to `~/.claude/hooks/` and optionally `~/.local/bin/` for PATH access.

**Pros:** Simple, focused, easy to alias as `cw`
**Cons:** Another script to maintain
**Effort:** small
**Risk:** low

### Option B — Absorb into unified `permissionsync` CLI (see todo 003)
Make `permissionsync launch feature-x` the entry point; `permissionsync-launch`
becomes a shim.
**Pros:** Single entry point
**Cons:** Depends on todo 003
**Effort:** medium (needs todo 003 first)

## Recommended Action

Implement Option A as a standalone script now; Option B can wrap it later.

Script logic:
```bash
NAME="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo worktree)}"
SETTINGS_FLAGS="--refine"
exec claude -w "$NAME" --settings <(~/.claude/hooks/merged-settings.sh $SETTINGS_FLAGS)
```

Parse `--log` / `--global-only` flags before the name argument.

Install to:
- `~/.claude/hooks/permissionsync-launch` (always)
- `~/.local/bin/permissionsync-launch` if directory exists (for PATH)

Update flake.nix to wrap as executable with runtime deps.

## Acceptance Criteria

- [ ] `permissionsync-launch [name]` launches claude in worktree with merged settings
- [ ] Defaults to current branch name when no name given
- [ ] `--log` flag passes `--from-log` to merged-settings.sh
- [ ] `--global-only` flag skips sibling worktree discovery
- [ ] install.sh and setup-hooks.sh copy to `~/.claude/hooks/`
- [ ] Optionally installed to `~/.local/bin/` when available
- [ ] flake.nix includes in executableScripts
- [ ] Unit tests cover flag parsing and command construction

## Work Log

### 2026-02-27 — Todo created

**By:** Claude Code

**Actions:**
- Extracted from implementation plan; can implement immediately (no blockers)

**Learnings:**
- Use `git rev-parse --git-common-dir` for worktree root discovery
- Default to branch name for ergonomic `permissionsync-launch` with no args
