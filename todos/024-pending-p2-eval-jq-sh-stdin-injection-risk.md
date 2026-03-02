---
status: pending
priority: p2
issue_id: "024"
tags: [security, code-review, eval, injection]
dependencies: []
---

# PSEC-03: eval + jq @sh Over Untrusted Stdin — Architectural Risk

## Problem Statement

Hook scripts parse their stdin input using:
```bash
eval "$(jq -r '@sh "TOOL_NAME=\(.tool_name // "") TOOL_INPUT=\(.tool_input // {} | tostring) CWD=\(.cwd // "")"' <<<"$INPUT")"
```

The `@sh` filter correctly single-quote-escapes values, so direct injection via known fields is not currently exploitable. However, this pattern is architecturally risky: any future field added to the `jq` expression that is not wrapped in `@sh` encoding would be immediately injectable. The `eval` surface is large, and `TOOL_INPUT` contains the entire tool input JSON — any downstream use of `$TOOL_INPUT` in a command context would be dangerous.

## Findings

- `permissionsync-log-permission.sh:58` — eval over TOOL_NAME, TOOL_INPUT, CWD, SESSION_ID
- `permissionsync-log-confirmed.sh:25` — same pattern for TOOL_NAME, TOOL_INPUT, CWD, OUTPUT
- Testing confirmed `@sh` correctly escapes `; rm -rf /` in tool_name — not currently exploitable
- Risk is forward-looking: the pattern is fragile under future extension

## Proposed Solutions

### Option 1: Replace eval with separate jq calls (Recommended)

```bash
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")
TOOL_INPUT=$(jq -r '.tool_input // {} | tostring' <<<"$INPUT")
CWD=$(jq -r '.cwd // empty' <<<"$INPUT")
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
```

- **Pros**: Eliminates eval entirely; each field independently and safely extracted; easy to review; no injection surface regardless of field content
- **Cons**: 3–4 `jq` invocations instead of 1 (minor performance cost per hook call)
- **Effort**: Small
- **Risk**: Low

### Option 2: Keep eval but add a comment + shellcheck annotation

Document the pattern and explain why it's safe, add `# shellcheck disable=SC2154` if needed. No code change.

- **Pros**: No performance cost
- **Cons**: Doesn't reduce the surface; next developer editing the jq expression may not know the @sh requirement
- **Effort**: Trivial
- **Risk**: Medium (future-unsafe)

### Option 3: Parse all fields with a single jq call writing to a temp file, then source it

Awkward and adds temp-file complexity. Not recommended.

## Recommended Action

Option 1. The performance cost (3–4 extra jq invocations per hook call) is negligible compared to the security clarity gained. The eval pattern is a well-known footgun in shell scripts.

## Technical Details

- **Affected Files**: `permissionsync-log-permission.sh:58`, `permissionsync-log-confirmed.sh:25`
- **Related**: Any future hook script that parses stdin JSON

## Acceptance Criteria

- [ ] `eval` removed from `permissionsync-log-permission.sh` stdin parsing
- [ ] `eval` removed from `permissionsync-log-confirmed.sh` stdin parsing
- [ ] Separate `jq` calls used for each variable
- [ ] shellcheck passes
- [ ] All tests pass

## Work Log

### 2026-03-02 - Identified in code review

**By:** Security review agent

**Actions:**
- Confirmed @sh escaping is correct for current fields
- Recommended replacement to eliminate the eval surface entirely
