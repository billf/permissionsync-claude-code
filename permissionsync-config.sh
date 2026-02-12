#!/usr/bin/env bash
# permissionsync-config.sh — shared data definitions for permissionsync-cc
#
# Sourced by permissionsync-lib.sh and other scripts.
# Must be Bash 3.2 compatible (no associative arrays).

# get_safe_subcommands BINARY → space-separated list of safe (read-only) subcommands
get_safe_subcommands() {
	case "$1" in
	git)
		# Truly read-only subcommands only. Excluded:
		#   config — can set hooks paths and create trojan aliases
		#   stash  — modifies working tree state
		echo "status log diff show branch tag describe rev-parse remote" \
			"ls-files ls-tree cat-file shortlog reflog blame" \
			"version help"
		;;
	cargo)
		# Excluded: build (build.rs runs arbitrary code), test/bench (execute code),
		#   doc (doc-tests execute code)
		echo "check clippy fmt metadata tree" \
			"read-manifest pkgid verify-project version"
		;;
	npm)
		# Excluded: test/start (run arbitrary scripts from package.json),
		#   audit (audit fix installs packages)
		echo "ls list outdated view info pack" \
			"config prefix root"
		;;
	nix)
		# Excluded: eval (arbitrary code), build (build hooks run code),
		#   develop/shell (execute shellHook), flake (fetches+evaluates remote code)
		echo "log show-derivation path-info store"
		;;
	docker)
		echo "ps images inspect logs stats top version info" \
			"events history port"
		;;
	kubectl)
		echo "get describe logs top version cluster-info" \
			"api-resources api-versions explain"
		;;
	pip)
		echo "list show freeze check"
		;;
	brew)
		echo "list info search outdated deps leaves config"
		;;
	*)
		echo ""
		;;
	esac
}

# get_indirection_type WORD → peeling type or empty string
# Types:
#   prefix    — strip word + any flags (sudo, nice, nohup, time, command)
#   prefix_kv — strip word + KEY=VAL pairs (env)
#   shell_c   — strip word + -c flag, unquote next arg (bash, sh, zsh, dash)
#   xargs     — strip word + flags
get_indirection_type() {
	case "$1" in
	env)
		echo "prefix_kv"
		;;
	sudo | nice | nohup | time | command)
		echo "prefix"
		;;
	xargs)
		echo "xargs"
		;;
	bash | sh | zsh | dash)
		echo "shell_c"
		;;
	*)
		echo ""
		;;
	esac
}

# get_indirection_flags_with_args WORD → flags that consume a separate argument
# for the indirection wrapper named WORD.
get_indirection_flags_with_args() {
	case "$1" in
	sudo)
		echo "-u --user -g --group -h --host -p --prompt -C --close-from -c --command -r --role -t --type -R --chroot -D --chdir"
		;;
	nice)
		echo "-n --adjustment"
		;;
	env)
		echo "-C --chdir -S --split-string"
		;;
	xargs)
		echo "-I --replace -L --max-lines -n --max-args -P --max-procs -s --max-chars -d --delimiter -E --eof -a --arg-file"
		;;
	*)
		echo ""
		;;
	esac
}

# is_blocklisted_binary WORD → 0 if WORD is a shell/interpreter that should
# never become a permission rule (allows arbitrary code execution).
# Matches both bare names and absolute paths (e.g. bash, /bin/bash).
is_blocklisted_binary() {
	local name="${1##*/}" # strip path prefix: /bin/bash → bash
	case "$name" in
	bash | sh | zsh | dash | ksh | csh | tcsh | fish | \
		python | python2 | python3 | ruby | perl | node | \
		eval | exec | source)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# is_shell_keyword WORD → 0 if WORD is a shell keyword/builtin that shouldn't
# become a permission rule binary (for, if, while, etc.)
is_shell_keyword() {
	case "$1" in
	for | if | then | else | elif | fi | while | until | do | done | \
		"case" | "esac" | select | in | function | time | coproc | \
		'{' | '}' | '!' | '[[' | ']]')
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# get_pre_subcommand_flags BINARY → flags (with arguments) to skip when finding
# the real subcommand. e.g. git -C /path log → subcommand is "log", not "-C".
get_pre_subcommand_flags() {
	case "$1" in
	git) echo "-C -c --git-dir --work-tree" ;;
	*) echo "" ;;
	esac
}

# get_alt_rule_prefixes BINARY → flag prefixes that should generate alternative
# permission rules. e.g. git log → also emit "git -C * log".
get_alt_rule_prefixes() {
	case "$1" in
	git) echo "-C" ;;
	*) echo "" ;;
	esac
}
