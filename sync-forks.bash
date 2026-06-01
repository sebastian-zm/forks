#!/usr/bin/env bash
#
# sync-forks.bash — daily fork/PR synchronization for this meta-repository.
#
# For each submodule that has an `upstream` remote (configured by setup.bash):
#
#   1. Fetch `upstream` and `origin`.
#   2. Fast-forward the fork's default branch (origin/HEAD, e.g. `main`) to the
#      upstream default branch, then push it to `origin`.
#   3. For every open PR you authored against the upstream whose head branch
#      lives in your fork, rebase that branch onto the branch the PR actually
#      targets, fetched fresh from the upstream (`upstream/<base>`). The rebase
#      is always staged on a throwaway `rebase/<head>` branch so the live PR
#      branch is never left in a broken state:
#        - clean rebase  -> force-push (--force-with-lease) the result to the
#                           real PR head, updating the open PR.
#        - conflict      -> abort, publish `rebase/<head>` at the PR's current
#                           (un-rebased) tip as a clean place to resolve by
#                           hand, and record the conflict in the report.
#
# This script performs only git/gh-read operations. It does NOT open issues:
# it writes a machine-readable report (default: ./.sync-forks-report.json) that
# the daily routine agent consumes to open/refresh deduplicated issues.
#
# Prerequisites (the daily routine ensures these before running this script):
#   - `./setup.bash` has run (submodules initialized, `upstream` remotes set).
#   - `gh` is installed and authenticated (GITHUB_TOKEN), and `jq` is present.
#
# Usage: ./sync-forks.bash
# Env:
#   REPORT_FILE   override report path (default: <repo>/.sync-forks-report.json)
#   DRY_RUN=1     do everything locally but skip every push (validate safely)
#
# Exit status: 0 if the script ran to completion (even if some PRs conflicted;
# inspect the report for per-item status). Non-zero only on setup errors.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

REPORT_FILE="${REPORT_FILE:-$repo_root/.sync-forks-report.json}"
DRY_RUN="${DRY_RUN:-0}"   # set DRY_RUN=1 to skip all pushes (validate only)
EVENTS="$(mktemp)"
trap 'rm -f "$EVENTS"' EXIT

log() { printf '%s\n' "$*" >&2; }

# git push wrapper honoring DRY_RUN. Usage: gpush <submodule-dir> <push-args...>
gpush() {
	local dir="$1"; shift
	if [ "$DRY_RUN" = "1" ]; then
		log "    [dry-run] would push: git -C $dir push $*"
		return 0
	fi
	git -C "$dir" push "$@" >/dev/null 2>&1
}

for tool in git gh jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		log "FATAL: required tool '$tool' not found on PATH"
		exit 1
	fi
done

# Emit one compact JSON object (a single report event) to the events buffer.
emit() { jq -n -c "$@" >> "$EVENTS"; }

# Derive owner/repo (e.g. moeru-ai/airi) from a GitHub remote URL.
# Handles https://github.com/owner/repo(.git) and git@github.com:owner/repo(.git)
slug_from_url() {
	local u="$1"
	u="${u%/}"               # strip trailing slash
	u="${u%.git}"            # strip trailing .git
	u="${u#*github.com/}"    # https form: drop through host + '/'
	u="${u#*github.com:}"    # ssh form:   drop through host + ':'
	printf '%s\n' "$u"
}

# ----- discover submodules from .gitmodules ---------------------------------
mapfile -t submodule_paths < <(
	git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
		| awk '{print $2}'
)

if [ "${#submodule_paths[@]}" -eq 0 ]; then
	log "No submodules found in .gitmodules; nothing to do."
fi

for path in "${submodule_paths[@]}"; do
	log "==> Submodule: $path"

	if [ ! -e "$path/.git" ]; then
		log "    skip: '$path' is not an initialized submodule (run setup.bash)"
		emit --arg path "$path" --arg status "error" \
			--arg detail "submodule not initialized" \
			'{type:"ff",path:$path,status:$status,detail:$detail}'
		continue
	fi

	if ! git -C "$path" remote get-url upstream >/dev/null 2>&1; then
		log "    skip: '$path' has no 'upstream' remote (run setup.bash)"
		emit --arg path "$path" --arg status "error" \
			--arg detail "no upstream remote configured" \
			'{type:"ff",path:$path,status:$status,detail:$detail}'
		continue
	fi

	fork_slug="$(slug_from_url "$(git -C "$path" remote get-url origin)")"
	up_slug="$(slug_from_url "$(git -C "$path" remote get-url upstream)")"
	fork_owner="${fork_slug%%/*}"

	# Fetch latest from both remotes.
	git -C "$path" fetch --prune --tags upstream >/dev/null 2>&1 \
		|| log "    warning: 'git fetch upstream' reported an error"
	git -C "$path" fetch --prune origin     >/dev/null 2>&1 \
		|| log "    warning: 'git fetch origin' reported an error"

	# Default branch name from the fork's HEAD (e.g. origin/main -> main).
	default_branch="$(git -C "$path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
	default_branch="${default_branch#origin/}"
	if [ -z "$default_branch" ]; then
		default_branch="$(git -C "$path" remote show origin 2>/dev/null \
			| sed -n 's/.*HEAD branch: //p')"
	fi
	if [ -z "$default_branch" ]; then
		log "    error: could not determine default branch for '$path'"
		emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
			--arg status "error" --arg detail "could not determine default branch" \
			'{type:"ff",path:$path,upstream:$up,fork:$fork,status:$status,detail:$detail}'
		continue
	fi
	log "    default branch: $default_branch  (fork=$fork_slug upstream=$up_slug)"

	# ----- fast-forward the default branch to upstream ----------------------
	# Point the local default branch at origin/<default>, then FF to upstream.
	git -C "$path" checkout -q -B "$default_branch" "origin/$default_branch" 2>/dev/null \
		|| git -C "$path" checkout -q "$default_branch" 2>/dev/null
	before="$(git -C "$path" rev-parse "$default_branch" 2>/dev/null)"
	upstream_tip="$(git -C "$path" rev-parse "upstream/$default_branch" 2>/dev/null)"

	if [ -z "$upstream_tip" ]; then
		log "    error: upstream/$default_branch not found"
		emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
			--arg db "$default_branch" --arg status "error" \
			--arg detail "upstream/$default_branch not found" \
			'{type:"ff",path:$path,upstream:$up,fork:$fork,default_branch:$db,status:$status,detail:$detail}'
	elif [ "$before" = "$upstream_tip" ]; then
		log "    fast-forward: already up to date"
		emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
			--arg db "$default_branch" --arg status "up_to_date" \
			'{type:"ff",path:$path,upstream:$up,fork:$fork,default_branch:$db,status:$status}'
	elif git -C "$path" merge --ff-only "upstream/$default_branch" >/dev/null 2>&1; then
		log "    fast-forward: $before -> $upstream_tip; pushing to origin"
		if gpush "$path" origin "$default_branch"; then
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--arg db "$default_branch" --arg status "updated" \
				--arg before "$before" --arg after "$upstream_tip" \
				'{type:"ff",path:$path,upstream:$up,fork:$fork,default_branch:$db,status:$status,before:$before,after:$after}'
		else
			log "    error: push of $default_branch to origin failed"
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--arg db "$default_branch" --arg status "error" \
				--arg detail "push of default branch to origin failed" \
				'{type:"ff",path:$path,upstream:$up,fork:$fork,default_branch:$db,status:$status,detail:$detail}'
		fi
	else
		log "    error: $default_branch has diverged from upstream (not a fast-forward)"
		emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
			--arg db "$default_branch" --arg status "failed" \
			--arg detail "fork '$default_branch' has diverged from upstream/$default_branch; not a fast-forward" \
			'{type:"ff",path:$path,upstream:$up,fork:$fork,default_branch:$db,status:$status,detail:$detail}'
		# Leave PR rebasing to run anyway against the (un-updated) default branch.
	fi

	# ----- rebase open PRs (head in the fork) onto the default branch -------
	prs_json="$(gh pr list -R "$up_slug" --state open --author "@me" \
		--json number,title,headRefName,baseRefName,headRepositoryOwner,isDraft \
		2>/dev/null)"
	if [ -z "$prs_json" ] || [ "$prs_json" = "null" ]; then
		prs_json="[]"
	fi

	pr_count="$(jq 'length' <<<"$prs_json")"
	log "    open PRs authored by you on $up_slug: $pr_count"

	while IFS=$'\t' read -r number head base head_owner draft title; do
		[ -z "${number:-}" ] && continue
		rebase_branch="rebase/$head"

		# Only branches whose head lives in the fork can be pushed/rebased.
		if [ "$head_owner" != "$fork_owner" ]; then
			log "    PR #$number ($head): skip — head repo '$head_owner' is not the fork"
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--argjson num "$number" --arg head "$head" --arg base "$base" \
				--arg title "$title" --arg status "skipped" \
				--arg detail "head branch lives in '$head_owner', not the fork" \
				'{type:"pr",path:$path,upstream:$up,fork:$fork,number:$num,head:$head,base:$base,title:$title,status:$status,detail:$detail}'
			continue
		fi
		# A PR whose head IS the default branch can't be rebased onto itself.
		if [ "$head" = "$default_branch" ]; then
			log "    PR #$number ($head): skip — head is the default branch"
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--argjson num "$number" --arg head "$head" --arg base "$base" \
				--arg title "$title" --arg status "skipped" \
				--arg detail "PR head is the default branch; cannot rebase onto itself" \
				'{type:"pr",path:$path,upstream:$up,fork:$fork,number:$num,head:$head,base:$base,title:$title,status:$status,detail:$detail}'
			continue
		fi

		git -C "$path" fetch origin "$head" >/dev/null 2>&1
		if ! git -C "$path" rev-parse "origin/$head" >/dev/null 2>&1; then
			log "    PR #$number ($head): error — origin/$head not found"
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--argjson num "$number" --arg head "$head" --arg base "$base" \
				--arg title "$title" --arg status "error" \
				--arg detail "origin/$head not found after fetch" \
				'{type:"pr",path:$path,upstream:$up,fork:$fork,number:$num,head:$head,base:$base,title:$title,status:$status,detail:$detail}'
			continue
		fi

		# Rebase onto the branch the PR actually targets, fetched fresh from the
		# upstream (e.g. upstream/main), not necessarily the fork's default branch.
		rebase_onto="upstream/$base"
		if ! git -C "$path" rev-parse --verify --quiet "$rebase_onto" >/dev/null 2>&1; then
			git -C "$path" fetch upstream "$base" >/dev/null 2>&1 || true
		fi
		if ! git -C "$path" rev-parse --verify --quiet "$rebase_onto" >/dev/null 2>&1; then
			log "    PR #$number ($head): error — base $rebase_onto not found on upstream"
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--argjson num "$number" --arg head "$head" --arg base "$base" \
				--arg title "$title" --arg status "error" \
				--arg detail "base branch '$base' not found on upstream" \
				'{type:"pr",path:$path,upstream:$up,fork:$fork,number:$num,head:$head,base:$base,title:$title,status:$status,detail:$detail}'
			continue
		fi

		# Stage the rebase on a throwaway branch; never touch the live PR branch
		# until we know the rebase is clean.
		git -C "$path" rebase --abort >/dev/null 2>&1 || true
		git -C "$path" checkout -q -B "$rebase_branch" "origin/$head"

		if git -C "$path" rebase "$rebase_onto" >/dev/null 2>&1; then
			rebased_tip="$(git -C "$path" rev-parse "$rebase_branch")"
			orig_tip="$(git -C "$path" rev-parse "origin/$head")"
			if [ "$rebased_tip" = "$orig_tip" ]; then
				log "    PR #$number ($head): already up to date on $rebase_onto"
				status="up_to_date"
				detail="already based on latest $rebase_onto"
			elif gpush "$path" --force-with-lease="$head:$orig_tip" \
					origin "$rebase_branch:$head"; then
				log "    PR #$number ($head): rebased cleanly and force-pushed"
				status="rebased"
				detail="rebased onto $rebase_onto and force-pushed to PR head"
				# Drop any stale rebase/<head> branch from a previous conflict.
				gpush "$path" origin --delete "$rebase_branch" || true
			else
				log "    PR #$number ($head): rebase clean but push was rejected"
				status="error"
				detail="rebase succeeded but force-push to PR head was rejected (head moved?)"
			fi
			git -C "$path" checkout -q --detach >/dev/null 2>&1
			git -C "$path" branch -D "$rebase_branch" >/dev/null 2>&1 || true
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--argjson num "$number" --arg head "$head" --arg base "$base" \
				--arg title "$title" --arg status "$status" --arg detail "$detail" \
				'{type:"pr",path:$path,upstream:$up,fork:$fork,number:$num,head:$head,base:$base,title:$title,status:$status,detail:$detail}'
		else
			# Conflict: capture the unmerged paths, abort, and publish the
			# un-rebased tip on rebase/<head> as a clean place to resolve.
			conflict_files="$(git -C "$path" diff --name-only --diff-filter=U 2>/dev/null \
				| jq -R -s -c 'split("\n") | map(select(length>0))')"
			[ -z "$conflict_files" ] && conflict_files="[]"
			git -C "$path" rebase --abort >/dev/null 2>&1 || true
			gpush "$path" --force origin "$rebase_branch" \
				|| log "    PR #$number ($head): warning — could not push $rebase_branch"
			git -C "$path" checkout -q --detach >/dev/null 2>&1
			git -C "$path" branch -D "$rebase_branch" >/dev/null 2>&1 || true
			log "    PR #$number ($head): CONFLICT rebasing onto $rebase_onto"
			emit --arg path "$path" --arg up "$up_slug" --arg fork "$fork_slug" \
				--argjson num "$number" --arg head "$head" --arg base "$base" \
				--arg title "$title" --arg status "conflict" \
				--arg rb "$rebase_branch" --argjson files "$conflict_files" \
				--arg detail "rebase onto $rebase_onto hit conflicts; un-rebased tip published to $rebase_branch for manual resolution" \
				'{type:"pr",path:$path,upstream:$up,fork:$fork,number:$num,head:$head,base:$base,title:$title,status:$status,rebase_branch:$rb,conflict_files:$files,detail:$detail}'
		fi
	done < <(jq -r '.[] | [.number, .headRefName, .baseRefName, .headRepositoryOwner.login, .isDraft, .title] | @tsv' <<<"$prs_json")
done

# ----- assemble the report ---------------------------------------------------
jq -s --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
	{
		generated_at: $generated_at,
		ff: [ .[] | select(.type=="ff") ],
		prs: [ .[] | select(.type=="pr") ],
		summary: {
			ff_updated:   [ .[] | select(.type=="ff" and .status=="updated") ] | length,
			ff_failed:    [ .[] | select(.type=="ff" and (.status=="failed" or .status=="error")) ] | length,
			pr_rebased:   [ .[] | select(.type=="pr" and .status=="rebased") ] | length,
			pr_conflicts: [ .[] | select(.type=="pr" and .status=="conflict") ] | length,
			pr_errors:    [ .[] | select(.type=="pr" and (.status=="error" or .status=="skipped")) ] | length
		}
	}' "$EVENTS" > "$REPORT_FILE"

log ""
log "==> Report written to $REPORT_FILE"
jq -r '.summary | to_entries[] | "    \(.key): \(.value)"' "$REPORT_FILE" >&2

# Echo report path on stdout for the routine agent to pick up.
printf '%s\n' "$REPORT_FILE"
