---
status: complete
priority: p3
issue_id: "028"
tags: [quality, code-review, cosmetic]
dependencies: []
---

# Stale Header Comments — 6 Scripts Still Reference Old Filenames

## Problem Statement

Six renamed scripts still have their old filename in the comment banner at line 2. This causes confusion when grepping the codebase for the old names, and makes the scripts look incomplete.

## Findings

| File | Line 2 current (stale) | Should be |
|---|---|---|
| `permissionsync-log-confirmed.sh` | `# log-confirmed.sh:` | `# permissionsync-log-confirmed.sh:` |
| `permissionsync-session-start.sh` | `# session-start.sh:` | `# permissionsync-session-start.sh:` |
| `permissionsync-worktree-create.sh` | `# worktree-create.sh:` | `# permissionsync-worktree-create.sh:` |
| `permissionsync-settings.sh` | `# merged-settings.sh` | `# permissionsync-settings.sh` |
| `permissionsync-sync.sh` | `# sync-permissions.sh` | `# permissionsync-sync.sh` |
| `permissionsync-worktree-sync.sh` | `# worktree-sync.sh` | `# permissionsync-worktree-sync.sh` |

Also: `permissionsync-log-permission-v1.sh:4` says "Install: copy to ~/.claude/hooks/log-permission.sh" — outdated install path.

Also: `tests/test-permissionsync-watch-config.sh` fixture JSON still uses old hook command names `log-permission-auto.sh` and `log-confirmed.sh` in the test fixtures (lines 59–60, 68, 76). The tests still pass because watch-config checks for `/.claude/hooks/` as a path fragment, but the fixtures don't reflect real-world state.

## Proposed Solutions

### Option 1: sed one-liners (Recommended)

```bash
sed -i '' 's|# log-confirmed.sh:|# permissionsync-log-confirmed.sh:|' permissionsync-log-confirmed.sh
sed -i '' 's|# session-start.sh:|# permissionsync-session-start.sh:|' permissionsync-session-start.sh
# etc.
```

Or just use the Edit tool per file.

- **Effort**: Trivial
- **Risk**: None

## Recommended Action

Fix all six header comments and the two test fixture files in a single commit.

## Technical Details

- **Affected Files**: 6 production scripts + `tests/test-permissionsync-watch-config.sh`
- **Database Changes**: No

## Acceptance Criteria

- [ ] All 6 scripts have correct filename in header comment
- [ ] `permissionsync-log-permission-v1.sh` install comment updated
- [ ] `test-permissionsync-watch-config.sh` fixture data uses current hook command names
- [ ] `grep -r 'log-confirmed.sh:' .` returns no results in production scripts
- [ ] All tests pass (no functional change)

## Work Log

### 2026-03-02 - Identified in architecture + pattern reviews

**By:** Architecture and pattern review agents
