#!/usr/bin/env bash
# permissionsync-launch.sh — launch claude in a new worktree with merged permissions
#
# Wraps: claude -w <name> --settings <(merged-settings.sh --refine [FLAGS])
#
# Usage:
#   permissionsync-launch.sh <worktree-name>
#   permissionsync-launch.sh [OPTIONS] <worktree-name> [-- CLAUDE_ARGS...]
#
# Options:
#   --from-log      Also include rules from JSONL approval log
#   --global-only   Skip sibling worktree discovery (global settings only)
#   --no-refine     Skip safe-subcommand refinement
#   --dry-run       Print the equivalent command without executing
#
# Examples:
#   permissionsync-launch.sh feature-x
#   permissionsync-launch.sh --from-log my-feature
#   permissionsync-launch.sh --dry-run feature-x -- --resume abc123

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGED_SETTINGS="${SCRIPT_DIR}/merged-settings.sh"

usage() {
	cat >&2 <<'USAGE'
Usage: permissionsync-launch.sh [OPTIONS] <worktree-name> [-- CLAUDE_ARGS...]

Launch claude in a new worktree with merged permission settings.
Equivalent to: claude -w <name> --settings <(merged-settings.sh --refine)

Options:
  --from-log      Include rules from JSONL approval log
  --global-only   Skip worktree rule discovery (global settings only)
  --no-refine     Skip safe-subcommand refinement (default: refinement on)
  --dry-run       Print the equivalent command without running it

Examples:
  permissionsync-launch.sh feature-x
  permissionsync-launch.sh --from-log feature-x
  permissionsync-launch.sh feature-x -- --resume <session-id>
USAGE
}

FROM_LOG=0
GLOBAL_ONLY=0
REFINE=1
DRY_RUN=0
WORKTREE_NAME=""
EXTRA_CLAUDE_ARGS=()
PARSING=1

for arg in "$@"; do
	if [[ $PARSING -eq 0 ]]; then
		EXTRA_CLAUDE_ARGS+=("$arg")
		continue
	fi
	case "$arg" in
	--from-log) FROM_LOG=1 ;;
	--global-only) GLOBAL_ONLY=1 ;;
	--no-refine) REFINE=0 ;;
	--dry-run) DRY_RUN=1 ;;
	--) PARSING=0 ;;
	-*)
		echo "Unknown option: $arg" >&2
		usage
		exit 1
		;;
	*)
		if [[ -z $WORKTREE_NAME ]]; then
			WORKTREE_NAME="$arg"
		else
			echo "Error: unexpected argument '$arg'" >&2
			usage
			exit 1
		fi
		;;
	esac
done

if [[ -z $WORKTREE_NAME ]]; then
	usage
	exit 1
fi

if [[ ! -x $MERGED_SETTINGS ]]; then
	echo "Error: merged-settings.sh not found at $MERGED_SETTINGS" >&2
	exit 1
fi

# Build merged-settings.sh argument list
MERGED_ARGS=()
[[ $REFINE -eq 1 ]] && MERGED_ARGS+=(--refine)
[[ $FROM_LOG -eq 1 ]] && MERGED_ARGS+=(--from-log)
[[ $GLOBAL_ONLY -eq 1 ]] && MERGED_ARGS+=(--global-only)

if [[ $DRY_RUN -eq 1 ]]; then
	merged_cmd="$MERGED_SETTINGS"
	for a in "${MERGED_ARGS[@]+"${MERGED_ARGS[@]}"}"; do
		merged_cmd+=" $(printf '%q' "$a")"
	done
	echo "claude -w $(printf '%q' "$WORKTREE_NAME") --settings <($merged_cmd)"
	if [[ ${#EXTRA_CLAUDE_ARGS[@]} -gt 0 ]]; then
		echo "  (additional claude args:$(printf ' %q' "${EXTRA_CLAUDE_ARGS[@]}"))"
	fi
	exit 0
fi

# Generate merged settings to a temp file, then launch claude
TEMP_SETTINGS=$(mktemp)
trap 'rm -f "$TEMP_SETTINGS"' EXIT

"$MERGED_SETTINGS" "${MERGED_ARGS[@]+"${MERGED_ARGS[@]}"}" >"$TEMP_SETTINGS"

claude -w "$WORKTREE_NAME" --settings "$TEMP_SETTINGS" \
	"${EXTRA_CLAUDE_ARGS[@]+"${EXTRA_CLAUDE_ARGS[@]}"}"
