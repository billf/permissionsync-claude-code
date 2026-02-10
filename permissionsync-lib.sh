#!/usr/bin/env bash
# permissionsync-lib.sh — shared functions for permissionsync-cc
#
# Sources permissionsync-config.sh for data definitions.
# Must be Bash 3.2 compatible (no associative arrays).

# Resolve the directory containing this script (works when sourced)
_PERMISSIONSYNC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=permissionsync-config.sh
source "${_PERMISSIONSYNC_LIB_DIR}/permissionsync-config.sh"

# peel_indirection CMD_STRING
#
# Strips indirection wrappers (env, sudo, xargs, bash -c, etc.) from a command.
# Sets globals:
#   PEELED_COMMAND    — the command after stripping all indirection
#   INDIRECTION_CHAIN — space-separated list of indirection wrappers found
#
# Max 10 iterations to avoid infinite loops.
# shellcheck disable=SC2034
peel_indirection() {
	local cmd="$1"
	PEELED_COMMAND=""
	INDIRECTION_CHAIN=""

	local i=0
	while [[ $i -lt 10 ]]; do
		# Trim leading whitespace
		cmd="${cmd#"${cmd%%[![:space:]]*}"}"
		[[ -z $cmd ]] && break

		# Extract the first word
		local first_word
		first_word="${cmd%% *}"
		# If cmd has no spaces, first_word == cmd
		if [[ $first_word == "$cmd" ]]; then
			# Single word left — no more indirection possible
			break
		fi

		local itype
		itype=$(get_indirection_type "$first_word")
		[[ -z $itype ]] && break

		# Record this indirection wrapper
		if [[ -n $INDIRECTION_CHAIN ]]; then
			INDIRECTION_CHAIN="${INDIRECTION_CHAIN} ${first_word}"
		else
			INDIRECTION_CHAIN="${first_word}"
		fi

		# Strip the wrapper based on type
		case "$itype" in
		prefix)
			# Strip the command word and any flags with their arguments
			cmd="${cmd#"$first_word"}"
			cmd="${cmd#"${cmd%%[![:space:]]*}"}"
			while [[ $cmd == -* ]]; do
				local flag="${cmd%% *}"
				cmd="${cmd#"$flag"}"
				cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				# If the flag is short (e.g. -u), consume its argument too
				# unless next word also starts with - (another flag)
				if [[ ${#flag} -eq 2 ]] && [[ $cmd != -* ]] && [[ -n $cmd ]]; then
					local flag_arg="${cmd%% *}"
					cmd="${cmd#"$flag_arg"}"
					cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				fi
			done
			;;
		prefix_kv)
			# Strip the command word, then any KEY=VAL pairs and flags
			cmd="${cmd#"$first_word"}"
			cmd="${cmd#"${cmd%%[![:space:]]*}"}"
			while [[ $cmd == *=* ]] || [[ $cmd == -* ]]; do
				local next_word="${cmd%% *}"
				if [[ $next_word == *=* ]] || [[ $next_word == -* ]]; then
					cmd="${cmd#"$next_word"}"
					cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				else
					break
				fi
			done
			;;
		shell_c)
			# Strip "bash -c", "sh -c" etc., then unquote the next arg
			cmd="${cmd#"$first_word"}"
			cmd="${cmd#"${cmd%%[![:space:]]*}"}"
			# Expect -c flag
			if [[ $cmd == -c* ]]; then
				cmd="${cmd#-c}"
				cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				# Unquote if wrapped in single or double quotes
				if [[ $cmd == \"*\" ]]; then
					cmd="${cmd#\"}"
					cmd="${cmd%\"}"
				elif [[ $cmd == \'*\' ]]; then
					cmd="${cmd#\'}"
					cmd="${cmd%\'}"
				fi
			fi
			;;
		xargs)
			# Strip xargs + any flags with their arguments
			cmd="${cmd#"$first_word"}"
			cmd="${cmd#"${cmd%%[![:space:]]*}"}"
			while [[ $cmd == -* ]]; do
				local flag="${cmd%% *}"
				cmd="${cmd#"$flag"}"
				cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				# Short flags (e.g. -I) consume the next word as argument
				if [[ ${#flag} -eq 2 ]] && [[ $cmd != -* ]] && [[ -n $cmd ]]; then
					local flag_arg="${cmd%% *}"
					cmd="${cmd#"$flag_arg"}"
					cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				fi
			done
			;;
		esac

		i=$((i + 1))
	done

	PEELED_COMMAND="$cmd"
}

# is_safe_subcommand BINARY SUBCMD
#
# Returns 0 (true) if SUBCMD is in the safe list for BINARY, 1 otherwise.
is_safe_subcommand() {
	local binary="$1" subcmd="$2"
	local safe_list
	safe_list=$(get_safe_subcommands "$binary")
	[[ -z $safe_list ]] && return 1

	local word
	for word in $safe_list; do
		if [[ $word == "$subcmd" ]]; then
			return 0
		fi
	done
	return 1
}

# has_subcommands BINARY
#
# Returns 0 (true) if this binary has a known subcommand list.
has_subcommands() {
	local safe_list
	safe_list=$(get_safe_subcommands "$1")
	[[ -n $safe_list ]]
}

# build_rule_v2 TOOL_NAME TOOL_INPUT_JSON
#
# Builds a permission rule string from a tool invocation.
# Sets globals:
#   RULE              — the permission rule (e.g. "Bash(git status *)")
#   EXACT_RULE        — the exact command rule (e.g. "Bash(git status --short)")
#   PEELED_COMMAND    — command after stripping indirection (from peel_indirection)
#   INDIRECTION_CHAIN — wrappers stripped (from peel_indirection)
#   BASE_COMMAND      — "binary subcommand" or just "binary"
#   IS_SAFE           — "true" if the subcommand is in the safe list
# shellcheck disable=SC2034
build_rule_v2() {
	local tool="$1" input="$2"

	RULE=""
	EXACT_RULE=""
	PEELED_COMMAND=""
	INDIRECTION_CHAIN=""
	BASE_COMMAND=""
	IS_SAFE="false"

	case "$tool" in
	Bash)
		local cmd
		cmd=$(echo "$input" | jq -r '.command // empty')
		if [[ -n $cmd ]]; then
			# Use only the first line for rule extraction (heredocs, pipes etc.
			# can span multiple lines — we only care about the command itself)
			local first_line
			first_line="${cmd%%$'\n'*}"

			# Peel indirection wrappers
			peel_indirection "$first_line"
			local effective="${PEELED_COMMAND}"

			# Extract binary and subcommand from the effective command
			local binary subcommand rest
			binary="${effective%% *}"
			# Validate binary looks like a command (not shell syntax/heredoc garbage)
			if [[ ! $binary =~ ^[a-zA-Z0-9_.~/-]+$ ]]; then
				binary=""
			fi
			if [[ $binary == "$effective" ]]; then
				# Single word command
				rest=""
			else
				rest="${effective#"$binary" }"
			fi
			subcommand="${rest%% *}"
			if [[ $subcommand == "$rest" ]] && [[ -z $rest ]]; then
				subcommand=""
			fi

			# Build the rule based on whether this binary has tracked subcommands
			if has_subcommands "$binary" && [[ -n $subcommand ]]; then
				RULE="Bash(${binary} ${subcommand} *)"
				BASE_COMMAND="${binary} ${subcommand}"
				if is_safe_subcommand "$binary" "$subcommand"; then
					IS_SAFE="true"
				fi
			elif [[ -n $binary ]]; then
				RULE="Bash(${binary} *)"
				BASE_COMMAND="${binary}"
			else
				RULE="Bash"
				BASE_COMMAND=""
			fi
			EXACT_RULE="Bash(${cmd})"
		else
			RULE="Bash"
			BASE_COMMAND=""
		fi
		;;
	Read | Write | Edit | MultiEdit)
		local file_path
		file_path=$(echo "$input" | jq -r '.file_path // empty')
		RULE="${tool}"
		if [[ -n $file_path ]]; then
			EXACT_RULE="${tool}(${file_path})"
		else
			EXACT_RULE="${tool}"
		fi
		BASE_COMMAND=""
		;;
	WebFetch)
		local url domain
		url=$(echo "$input" | jq -r '.url // empty')
		if [[ -n $url ]]; then
			domain=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
			RULE="WebFetch(domain:${domain})"
		else
			RULE="WebFetch"
		fi
		EXACT_RULE="$RULE"
		BASE_COMMAND=""
		;;
	mcp__*)
		RULE="$tool"
		EXACT_RULE="$tool"
		BASE_COMMAND=""
		;;
	*)
		RULE="$tool"
		EXACT_RULE="$tool"
		BASE_COMMAND=""
		;;
	esac
}
