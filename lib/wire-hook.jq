# wire-hook.jq — reusable jq function for hook wiring in settings.json
#
# Usage from bash:
#   jq -L lib/ \
#     --arg event "PostToolUse" \
#     --arg cmd "$HOOKS_DIR/my-hook.sh" \
#     --arg matcher "*" \
#     --argjson evict '["old-hook.sh","my-hook.sh"]' \
#     'include "wire-hook"; wire_hook($event; $cmd; $matcher; $evict)' \
#     settings.json

# wire_hook(event; cmd; matcher; evict)
#
# Idempotently wires a hook command into .hooks[event].
# Removes all commands in the evict array first, then appends a fresh entry.
#
# Parameters:
#   event  — hook event name (e.g. "PostToolUse", "SessionStart")
#   cmd    — the command string to wire
#   matcher — matcher value ("*", "user_settings") or "" for no matcher field
#   evict  — JSON array of command strings to remove (should include cmd itself)
def wire_hook(event; cmd; matcher; evict):
  .hooks //= {} |
  .hooks[event] //= [] |
  .hooks[event] = (
    [
      .hooks[event][]
      | .hooks = (
          (.hooks // [])
          | map(select(.command as $c | (evict | any(. == $c)) | not))
        )
      | select((.hooks | length) > 0)
    ] + [
      (if matcher == "" then {} else {matcher: matcher} end)
      + {hooks: [{type: "command", command: cmd}]}
    ]
  );
