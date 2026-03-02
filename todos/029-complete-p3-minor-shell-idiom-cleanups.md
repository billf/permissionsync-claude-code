---
status: complete
priority: p3
issue_id: "029"
tags: [quality, code-review, bash, idioms]
dependencies: []
---

# Minor Shell Idiom Cleanups

## Problem Statement

Several minor shell anti-patterns were identified across the codebase. None are bugs, but they violate the project's stated convention of minimizing subprocesses and preferring Bash builtins.

## Findings

| Severity | File | Line | Issue |
|---|---|---|---|
| Medium | `permissionsync-worktree-create.sh` | 8 | `INPUT=$(cat)` should be `INPUT=$(</dev/stdin)` |
| Medium | `permissionsync-install.sh` | ~51 | `echo "$rules_json" \| jq` should use `jq <<<"$rules_json"` |
| Medium | `permissionsync-setup.sh` | ~56 | Same as above |
| Low | `permissionsync.sh` | 64–65 | 3-subprocess chain `jq \| grep \| head \| cut` for mode extraction — could be one jq expression |
| Low | `permissionsync.sh` | 70–76 | `echo "$old_cmd" \| grep -q 'PATTERN'` — 3 subprocess forks; use `[[ $old_cmd == *PATTERN* ]]` |
| Low | `permissionsync.sh` | 60 + 87 | Two separate `[[ -f $settings ]]` blocks 27 lines apart for hook checks — could be consolidated |

### Details

**`INPUT=$(cat)` vs `INPUT=$(</dev/stdin)`**: The `$(cat)` form forks a subprocess. `$(</dev/stdin)` reads via Bash's built-in file descriptor handling. The project already uses `$(</dev/stdin)` in other scripts (e.g., `permissionsync-log-permission.sh:56`).

**`echo | jq` vs `jq <<<`**: `echo "$var" | jq` forks a subshell. `jq <<<"$var"` uses a here-string, which Bash implements without forking (or with minimal overhead). The project explicitly states "Minimize subprocesses — prefer Bash parameter expansion over sed/awk/cut".

**`echo | grep -q` vs `[[ ]]`**: The `permissionsync.sh` legacy mode detection (lines 70–76) uses three `echo "$old_cmd" | grep -q 'PATTERN'` calls. Each forks a subprocess. `[[ $old_cmd == *PATTERN* ]]` is a pure Bash builtin with zero subprocess cost.

## Proposed Solutions

One commit fixing all items:

```bash
# permissionsync-worktree-create.sh
INPUT=$(</dev/stdin)   # was $(cat)

# permissionsync-install.sh / permissionsync-setup.sh
jq --argjson rules "$rules_json" ... <<<"$rules_json"   # was echo "$rules_json" | jq

# permissionsync.sh legacy mode detection
if [[ $old_cmd == *CLAUDE_PERMISSION_WORKTREE* ]]; then
    mode="worktree (legacy — re-run installer to upgrade)"
elif [[ $old_cmd == *CLAUDE_PERMISSION_AUTO* ]]; then
    mode="auto (legacy — re-run installer to upgrade)"
else
    mode="log (legacy — re-run installer to upgrade)"
fi
```

- **Effort**: Small
- **Risk**: None (pure equivalents)

## Recommended Action

Fix all in one commit. The `[[ ]]` pattern match change in `permissionsync.sh` is the highest value — it also makes the code clearer and removes 3 subprocesses per `status` invocation.

## Technical Details

- **Affected Files**: `permissionsync-worktree-create.sh`, `permissionsync-install.sh`, `permissionsync-setup.sh`, `permissionsync.sh`

## Acceptance Criteria

- [ ] `INPUT=$(cat)` replaced with `INPUT=$(</dev/stdin)` in `permissionsync-worktree-create.sh`
- [ ] `echo "$rules_json" | jq` replaced with `jq <<<"$rules_json"` in both installers
- [ ] `echo "$old_cmd" | grep -q` replaced with `[[ $old_cmd == *PATTERN* ]]` in `permissionsync.sh`
- [ ] shellcheck passes
- [ ] shfmt -d -s shows no diffs
- [ ] All tests pass

## Work Log

### 2026-03-02 - Identified in pattern + simplicity reviews

**By:** Pattern and simplicity review agents
