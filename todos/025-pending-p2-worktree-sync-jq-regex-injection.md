---
status: pending
priority: p2
issue_id: "025"
tags: [security, code-review, regex, injection, worktree]
dependencies: []
---

# PSEC-06: jq test() Uses Unescaped Worktree Paths as Oniguruma Regex

## Problem Statement

`permissionsync-worktree-sync.sh` builds a regex pattern from worktree paths joined by `|` and passes it to `jq test($pattern)`. Worktree paths with regex metacharacters (`.`, `(`, `)`, `[`, `|`) produce malformed or unintentionally broad regex. A crafted worktree path with `|` could inject a regex OR branch pointing to an unrelated directory, causing that directory's JSONL log entries to be treated as sibling-worktree rules.

**Example:** Worktree at `/home/user/project.v2` — the `.` matches any character, so `/home/user/projectXv2` also matches. More seriously, a path like `/tmp/a|/etc` would cause `/etc` CWD entries to match.

## Findings

- `permissionsync-worktree-sync.sh` lines 96–110: paths joined with `|`, passed to `jq test($pattern)` (Oniguruma regex)
- Worktree paths can contain metacharacters in legitimate project names (dots, parens, brackets)
- An adversarially named git worktree (or a path a user creates for another purpose) could inject arbitrary regex branches

## Proposed Solutions

### Option 1: Use `startswith` in jq instead of regex (Recommended)

Build a jq filter using literal `startswith` tests:

```bash
jq_expr='select(.cwd != null and ('
sep=''
for ((i = 0; i < WORKTREE_COUNT; i++)); do
    jq_expr+="${sep}(.cwd | startswith(\$wt${i}))"
    sep=' or '
done
jq_expr+='))'

# Build --arg args for each worktree path
jq_args=()
for ((i = 0; i < WORKTREE_COUNT; i++)); do
    jq_args+=(--arg "wt${i}" "${WORKTREE_PATHS[$i]}")
done

jq -r "${jq_args[@]}" "${jq_expr} | .rule // empty" "$LOG_FILE"
```

- **Pros**: No regex — literal prefix match; safe for all path characters; behavior matches intent
- **Cons**: jq_args loop with dynamic --arg names is slightly verbose
- **Effort**: Small
- **Risk**: Low

### Option 2: Escape regex metacharacters in each path before joining

```bash
escape_regex() { printf '%s' "$1" | sed 's/[.^$*+?{}|()[\]\\]/\\&/g'; }
for ((i = 0; i < WORKTREE_COUNT; i++)); do
    escaped=$(escape_regex "${WORKTREE_PATHS[$i]}")
    ...
done
```

- **Pros**: Minimal restructuring
- **Cons**: sed subprocess per path; escape correctness is easy to get wrong; regex is still the wrong tool for literal prefix matching
- **Effort**: Small
- **Risk**: Medium (escape completeness)

## Recommended Action

Option 1. `startswith` is the semantically correct tool for path prefix matching and has no injection surface.

## Technical Details

- **Affected Files**: `permissionsync-worktree-sync.sh` lines 90–120
- **Related Components**: `discover_worktrees()` in lib/permissionsync-lib.sh
- **Database Changes**: No

## Acceptance Criteria

- [ ] `jq test($pattern)` replaced with `startswith`-based jq filter
- [ ] Path with `.` in name does not over-match adjacent paths
- [ ] Path with `|` in name does not inject additional regex branches
- [ ] All existing worktree-sync tests pass

## Work Log

### 2026-03-02 - Identified in code review

**By:** Security review agent
