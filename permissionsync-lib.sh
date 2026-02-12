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
			# Only treat as indirection if -c flag follows (bash -c "cmd")
			# bash script.sh is NOT indirection — it's running a script
			local rest_after="${cmd#"$first_word"}"
			rest_after="${rest_after#"${rest_after%%[![:space:]]*}"}"
			if [[ $rest_after != -c* ]]; then
				# Not "bash -c" — undo the indirection chain entry and stop
				if [[ $INDIRECTION_CHAIN == "$first_word" ]]; then
					INDIRECTION_CHAIN=""
				else
					INDIRECTION_CHAIN="${INDIRECTION_CHAIN% "$first_word"}"
				fi
				break
			fi
			# Strip "bash -c", then unquote the next arg
			cmd="${rest_after#-c}"
			cmd="${cmd#"${cmd%%[![:space:]]*}"}"
			# Unquote if wrapped in single or double quotes
			if [[ $cmd == \"*\" ]]; then
				cmd="${cmd#\"}"
				cmd="${cmd%\"}"
			elif [[ $cmd == \'*\' ]]; then
				cmd="${cmd#\'}"
				cmd="${cmd%\'}"
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
#   PEELED_COMMAND    — command after stripping indirection (from peel_indirection)
#   INDIRECTION_CHAIN — wrappers stripped (from peel_indirection)
#   BASE_COMMAND      — "binary subcommand" or just "binary"
#   IS_SAFE           — "true" if the subcommand is in the safe list
# shellcheck disable=SC2034
build_rule_v2() {
	local tool="$1" input="$2"

	RULE=""
	PEELED_COMMAND=""
	INDIRECTION_CHAIN=""
	BASE_COMMAND=""
	IS_SAFE="false"

	case "$tool" in
	Bash)
		local cmd
		cmd=$(jq -r '.command // empty' <<<"$input")
		if [[ -n $cmd ]]; then
			# Use only the first line for rule extraction (heredocs, pipes etc.
			# can span multiple lines — we only care about the command itself)
			local first_line
			first_line="${cmd%%$'\n'*}"

			# SEC-08: Multiline commands are never safe (second+ lines
			# could contain arbitrary code invisible to the classifier)
			local is_multiline=0
			if [[ $cmd == *$'\n'* ]]; then
				is_multiline=1
			fi

			# SEC-01: Commands with shell metacharacters are never safe
			# (e.g. "git log && curl evil.com" would bypass safe classification)
			local has_metachar=0
			case "$first_line" in
			*'&&'* | *'||'* | *'|'* | *';'*)
				has_metachar=1
				;;
			esac
			# shellcheck disable=SC2016
			case "$first_line" in
			*'`'* | *'$('* | *'>('* | *'<('*)
				has_metachar=1
				;;
			esac
			# SEC-03: I/O redirections can write to arbitrary files
			# (e.g. "git log > /tmp/stolen" would exfiltrate data)
			case "$first_line" in
			*'>>'* | *'&>'* | *'<<<'* | *'2>'*)
				has_metachar=1
				;;
			esac
			# Check for standalone > or < (not part of >>, &>, 2>, <<<, >(, <(
			# which are already caught above)
			local _redir_pat='[^>>&<]>[^>]|^>[^>]|[^<]<[^<(]|^<[^<(]'
			if [[ $first_line =~ $_redir_pat ]]; then
				has_metachar=1
			fi
			# SEC-04: Background operator & (but not &&, already caught)
			# Strip all && first, then check for remaining &
			local _fl_bg="${first_line//&&/}"
			case "$_fl_bg" in
			*'&'*)
				has_metachar=1
				;;
			esac

			# Peel indirection wrappers
			peel_indirection "$first_line"
			local effective="${PEELED_COMMAND}"

			# Extract binary and subcommand from the effective command
			local binary subcommand rest
			binary="${effective%% *}"
			# Validate binary looks like a command (not shell syntax/keywords/interpreters/garbage)
			if [[ ! $binary =~ ^[a-zA-Z0-9_.~/-]+$ ]] || is_shell_keyword "$binary" || is_blocklisted_binary "$binary"; then
				binary=""
			fi
			if [[ $binary == "$effective" ]]; then
				# Single word command
				rest=""
			else
				rest="${effective#"$binary" }"
			fi

			# Skip pre-subcommand flags (e.g. git -C /path log → "log")
			local skip_flags
			skip_flags=$(get_pre_subcommand_flags "$binary")
			if [[ -n $skip_flags ]]; then
				while [[ -n $rest ]]; do
					local next_word="${rest%% *}"
					local is_skip=0
					local sf
					for sf in $skip_flags; do
						if [[ $next_word == "$sf" ]]; then
							is_skip=1
							break
						fi
					done
					if [[ $is_skip -eq 1 ]]; then
						# Skip the flag
						rest="${rest#"$next_word"}"
						rest="${rest#"${rest%%[![:space:]]*}"}"
						# Skip its argument
						if [[ -n $rest ]]; then
							local skip_arg="${rest%% *}"
							rest="${rest#"$skip_arg"}"
							rest="${rest#"${rest%%[![:space:]]*}"}"
						fi
					else
						break
					fi
				done
			fi

			subcommand="${rest%% *}"
			if [[ $subcommand == "$rest" ]] && [[ -z $rest ]]; then
				subcommand=""
			fi

			# Build the rule based on whether this binary has tracked subcommands
			if has_subcommands "$binary" && [[ -n $subcommand ]]; then
				RULE="Bash(${binary} ${subcommand} *)"
				BASE_COMMAND="${binary} ${subcommand}"
				# Only mark safe if no metacharacters and not multiline
				if [[ $has_metachar -eq 0 ]] && [[ $is_multiline -eq 0 ]] &&
					is_safe_subcommand "$binary" "$subcommand"; then
					IS_SAFE="true"
				fi
			elif [[ -n $binary ]]; then
				RULE="Bash(${binary} *)"
				BASE_COMMAND="${binary}"
			else
				RULE="Bash"
				BASE_COMMAND=""
			fi
		else
			RULE="Bash"
			BASE_COMMAND=""
		fi
		;;
	Read | Write | Edit | MultiEdit)
		local file_path
		file_path=$(jq -r '.file_path // empty' <<<"$input")
		RULE="${tool}"
		BASE_COMMAND=""
		;;
	WebFetch)
		local url domain
		url=$(jq -r '.url // empty' <<<"$input")
		if [[ -n $url ]]; then
			# Extract domain using Bash parameter expansion (no subprocess)
			domain="${url#*://}"
			domain="${domain%%/*}"
			RULE="WebFetch(domain:${domain})"
		else
			RULE="WebFetch"
		fi
		BASE_COMMAND=""
		;;
	mcp__*)
		RULE="$tool"
		BASE_COMMAND=""
		;;
	*)
		RULE="$tool"
		BASE_COMMAND=""
		;;
	esac
}
