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
			local arg_flags
			arg_flags=$(get_indirection_flags_with_args "$first_word")
			while [[ $cmd == -* ]]; do
				local flag="${cmd%% *}"
				cmd="${cmd#"$flag"}"
				cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				# "--" ends wrapper options (next token is the wrapped command).
				[[ $flag == "--" ]] && break
				# Long --flag=value form already includes its value.
				[[ $flag == --*=* ]] && continue

				local takes_arg=0
				local af
				for af in $arg_flags; do
					if [[ $af == "$flag" ]]; then
						takes_arg=1
						break
					fi
				done
				if [[ $takes_arg -eq 1 ]] && [[ -n $cmd ]]; then
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
			local arg_flags
			arg_flags=$(get_indirection_flags_with_args "$first_word")
			while [[ -n $cmd ]]; do
				local next_word="${cmd%% *}"
				if [[ $next_word == *=* ]]; then
					cmd="${cmd#"$next_word"}"
					cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				elif [[ $next_word == -* ]]; then
					cmd="${cmd#"$next_word"}"
					cmd="${cmd#"${cmd%%[![:space:]]*}"}"
					[[ $next_word == "--" ]] && break
					[[ $next_word == --*=* ]] && continue
					local takes_arg=0
					local af
					for af in $arg_flags; do
						if [[ $af == "$next_word" ]]; then
							takes_arg=1
							break
						fi
					done
					if [[ $takes_arg -eq 1 ]] && [[ -n $cmd ]]; then
						local flag_arg="${cmd%% *}"
						cmd="${cmd#"$flag_arg"}"
						cmd="${cmd#"${cmd%%[![:space:]]*}"}"
					fi
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
			local arg_flags
			arg_flags=$(get_indirection_flags_with_args "$first_word")
			while [[ $cmd == -* ]]; do
				local flag="${cmd%% *}"
				cmd="${cmd#"$flag"}"
				cmd="${cmd#"${cmd%%[![:space:]]*}"}"
				[[ $flag == "--" ]] && break
				[[ $flag == --*=* ]] && continue

				local takes_arg=0
				local af
				for af in $arg_flags; do
					if [[ $af == "$flag" ]]; then
						takes_arg=1
						break
					fi
				done
				if [[ $takes_arg -eq 1 ]] && [[ -n $cmd ]]; then
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

# is_in_worktree
#
# Fast guard — returns 0 if we're in a git worktree (either a linked worktree
# or the main worktree with siblings). Avoids the cost of `git worktree list`
# on every hook invocation when there are no worktrees.
# Returns 1 if not in a git repo or no worktrees exist.
is_in_worktree() {
	local git_dir common_dir
	git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
	common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1

	# Resolve to absolute paths for reliable comparison
	git_dir=$(cd "$git_dir" && pwd)
	common_dir=$(cd "$common_dir" && pwd)

	if [[ $git_dir != "$common_dir" ]]; then
		# We're in a linked worktree (.git is a file pointing elsewhere)
		return 0
	fi

	# We're in the main worktree — check if siblings exist
	if [[ -d "${common_dir}/worktrees" ]]; then
		# Check if the worktrees/ dir has any entries
		local entries
		entries=$(ls -A "${common_dir}/worktrees" 2>/dev/null)
		if [[ -n $entries ]]; then
			return 0
		fi
	fi

	return 1
}

# discover_worktrees [EXCLUDE_CURRENT]
#
# Parses `git worktree list --porcelain` to extract worktree paths.
# Skips bare repos and paths that don't exist on disk.
# If EXCLUDE_CURRENT=1 (default), omits the current worktree.
# Sets:
#   WORKTREE_PATHS — indexed array of worktree paths
#   WORKTREE_COUNT — number of paths found
# Bash 3.2 compatible (indexed arrays, not associative).
# shellcheck disable=SC2034
discover_worktrees() {
	local exclude_current="${1:-1}"
	WORKTREE_PATHS=()
	WORKTREE_COUNT=0

	local current_wt
	current_wt=$(git rev-parse --show-toplevel 2>/dev/null) || return 1

	local line wt_path is_bare
	is_bare=0
	wt_path=""

	while IFS= read -r line || [[ -n $line ]]; do
		case "$line" in
		"worktree "*)
			wt_path="${line#worktree }"
			is_bare=0
			;;
		"bare")
			is_bare=1
			;;
		"")
			# End of a worktree block — process it
			if [[ -n $wt_path ]] && [[ $is_bare -eq 0 ]] && [[ -d $wt_path ]]; then
				if [[ $exclude_current -eq 1 ]] && [[ $wt_path == "$current_wt" ]]; then
					: # skip current
				else
					WORKTREE_PATHS+=("$wt_path")
				fi
			fi
			wt_path=""
			is_bare=0
			;;
		esac
	done < <(git worktree list --porcelain 2>/dev/null)

	# Process the last block (git output may not end with a blank line)
	if [[ -n $wt_path ]] && [[ $is_bare -eq 0 ]] && [[ -d $wt_path ]]; then
		if [[ $exclude_current -eq 1 ]] && [[ $wt_path == "$current_wt" ]]; then
			: # skip current
		else
			WORKTREE_PATHS+=("$wt_path")
		fi
	fi

	WORKTREE_COUNT=${#WORKTREE_PATHS[@]}
}

# read_sibling_rules
#
# Reads permission rules from sibling worktrees' .claude/settings.local.json.
# Calls discover_worktrees 1 (exclude current) to get sibling paths.
# For each sibling, extracts permissions.allow[] via jq.
# Deduplicates with sort -u.
# Sets:
#   SIBLING_RULES      — newline-separated unique rules
#   SIBLING_RULE_COUNT — number of unique rules found
# Returns 1 if no sibling worktrees exist or no rules found.
# shellcheck disable=SC2034
read_sibling_rules() {
	discover_worktrees 1 || return 1
	[[ $WORKTREE_COUNT -eq 0 ]] && return 1

	local all_rules="" i settings_file rules
	for ((i = 0; i < WORKTREE_COUNT; i++)); do
		settings_file="${WORKTREE_PATHS[$i]}/.claude/settings.local.json"
		[[ -f $settings_file ]] || continue
		rules=$(jq -r '.permissions.allow[]? // empty' "$settings_file" 2>/dev/null) || continue
		if [[ -n $rules ]]; then
			all_rules="${all_rules}${rules}"$'\n'
		fi
	done

	SIBLING_RULES=$(echo "$all_rules" | sed '/^$/d' | sort -u)
	if [[ -z $SIBLING_RULES ]]; then
		SIBLING_RULE_COUNT=0
		return 1
	fi

	SIBLING_RULE_COUNT=$(echo "$SIBLING_RULES" | wc -l | tr -d ' ')
	return 0
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
