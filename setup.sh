#!/usr/bin/env bash
#
# setup.sh — configure submodules and their fork/upstream remotes.
#
# A submodule's remotes live in the superproject's .git/modules/<name>/config,
# which is NOT tracked by git and NOT pushed. So a fresh clone only restores
# `origin`. Run this script after cloning to (re)create the `upstream` remotes
# needed to pull commits from the original repositories. It is idempotent.
#
# Usage: ./setup.sh

set -euo pipefail

# Map of submodule path -> upstream URL to fetch original commits from.
declare -A UPSTREAMS=(
	["airi"]="https://github.com/moeru-ai/airi.git"
	["eventa"]="https://github.com/moeru-ai/eventa.git"
	["clipboard-sync"]="https://github.com/dnut/clipboard-sync.git"
)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

echo "==> Initializing submodules"
git submodule update --init --recursive

set_remote() {
	# set_remote <git-dir-path> <remote-name> <url>
	local dir="$1" name="$2" url="$3"
	if git -C "$dir" remote get-url "$name" >/dev/null 2>&1; then
		git -C "$dir" remote set-url "$name" "$url"
		echo "    updated remote '$name' -> $url"
	else
		git -C "$dir" remote add "$name" "$url"
		echo "    added remote '$name' -> $url"
	fi
}

for path in "${!UPSTREAMS[@]}"; do
	url="${UPSTREAMS[$path]}"
	echo "==> Configuring '$path'"
	if [ ! -d "$path/.git" ] && [ ! -f "$path/.git" ]; then
		echo "    skipping: '$path' is not an initialized submodule" >&2
		continue
	fi
	set_remote "$path" upstream "$url"
	# Guard against accidental pushes to the original repository.
	git -C "$path" remote set-url --push upstream DISABLE
	echo "    push to 'upstream' disabled"
	git -C "$path" fetch upstream --tags
done

echo "==> Done. Remotes configured."
