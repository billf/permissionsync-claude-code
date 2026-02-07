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

# Known indirection prefixes for rule expansion (regular array, Bash 3.2 safe)
INDIRECTION_PREFIXES=("xargs" "env" "bash -c" "sh -c" "sudo" "nice" "nohup" "time" "command")
