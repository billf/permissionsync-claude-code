#!/usr/bin/env bash
# permissionsync-config.sh — shared data definitions for permissionsync-cc
#
# Sourced by permissionsync-lib.sh and other scripts.
# Must be Bash 3.2 compatible (no associative arrays).

# get_safe_subcommands BINARY → space-separated list of safe (read-only) subcommands
get_safe_subcommands() {
	case "$1" in
	git)
		echo "status log diff show branch tag describe rev-parse remote" \
			"ls-files ls-tree cat-file shortlog reflog blame" \
			"config stash version help"
		;;
	cargo)
		echo "check build clippy test bench doc fmt metadata tree" \
			"read-manifest pkgid verify-project version"
		;;
	npm)
		echo "ls list outdated view info pack audit test start" \
			"config prefix root"
		;;
	nix)
		echo "eval build log show-derivation path-info store" \
			"flake develop shell"
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

# Known indirection prefixes for rule expansion (regular array, Bash 3.2 safe)
# shellcheck disable=SC2034
INDIRECTION_PREFIXES=("xargs" "env" "bash -c" "sh -c" "sudo" "nice" "nohup" "time" "command")
