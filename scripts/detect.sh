#!/usr/bin/env bash
# Phase 1: read config, discover upstreams, and decide what each one needs.
# Deterministic — no LLM involvement. Writes $FT_STATE_FILE for later phases.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

normalize_config() {
	local config_path="${FT_CONFIG_PATH:-.github/fork-tender.yml}"
	if [[ -f "$config_path" ]]; then
		yq -o=json '.' "$config_path" > "$FT_CONFIG_FILE"
		log "loaded config from ${config_path}"
	else
		echo '{}' > "$FT_CONFIG_FILE"
		log "no config at ${config_path}, using defaults"
	fi

	local strategy ff_mode
	strategy=$(config_get '.strategy // "merge"')
	ff_mode=$(config_get '.ff // "auto"')
	[[ "$strategy" == 'merge' || "$strategy" == 'rebase' ]] \
		|| die "config: strategy must be 'merge' or 'rebase', got '${strategy}'"
	[[ "$ff_mode" == 'auto' || "$ff_mode" == 'issue' ]] \
		|| die "config: ff must be 'auto' or 'issue', got '${ff_mode}'"
}

# The GitHub parent of this fork ("owner/repo"), or empty.
detect_parent() {
	if skip_gh || [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
		return 0
	fi
	gh api "repos/${GITHUB_REPOSITORY}" --jq '.parent.full_name // empty' 2> /dev/null || true
}

# Resolve an upstream's default branch without fetching everything.
remote_default_branch() {
	local url=$1
	git ls-remote --symref "$url" HEAD 2> /dev/null \
		| awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'
}

# Markers we stash in PR/issue bodies to make reruns idempotent.
pr_state_for_branch() {
	local branch=$1
	if skip_gh; then
		echo '{}'
		return 0
	fi
	# Most recent PR (any state) whose head is our sync branch.
	gh pr list --head "$branch" --state all --limit 1 \
		--json number,state,body,isDraft \
		--jq '.[0] // {}' 2> /dev/null || echo '{}'
}

main() {
	mkdir -p "$FT_STATE_DIR"
	setup_git_auth
	normalize_config

	local base_branch base_sha
	base_branch=$(git branch --show-current)
	[[ -n "$base_branch" ]] || die 'detached HEAD: check out your default branch before running fork-tender'
	base_sha=$(git rev-parse HEAD)
	git rev-parse --verify --quiet 'HEAD~0' > /dev/null || die 'repository has no commits'

	local parent strategy ff_mode
	parent=$(detect_parent)
	strategy=$(config_get '.strategy // "merge"')
	ff_mode=$(config_get '.ff // "auto"')

	# Upstream list: config wins; otherwise fall back to the GitHub parent.
	local upstream_specs
	upstream_specs=$(config_get '[(.upstreams // [])[] | {repo: (.repo // ""), url: (.url // ""), branch: (.branch // ""), parent: (.parent // false)}] | @json')
	if [[ $(jq -r 'length' <<< "$upstream_specs") -eq 0 ]]; then
		[[ -n "$parent" ]] || die 'no upstreams configured and this repository is not a GitHub fork (no parent)'
		upstream_specs=$(jq -cn --arg repo "$parent" '[{repo: $repo, url: "", branch: "", parent: true}]')
	fi

	if [[ "$strategy" == 'rebase' && $(jq -r 'length' <<< "$upstream_specs") -gt 1 ]]; then
		die "strategy 'rebase' supports exactly one upstream; use 'merge' for multi-upstream repos"
	fi

	local entries='[]' spec
	while IFS= read -r spec; do
		local repo url branch
		repo=$(jq -r '.repo' <<< "$spec")
		url=$(jq -r '.url' <<< "$spec")
		[[ -n "$url" || -n "$repo" ]] || die 'config: each upstream needs a repo or url'
		[[ -n "$url" ]] || url="https://github.com/${repo}.git"
		[[ -n "$repo" ]] || repo=$(basename "$url" .git)

		branch=$(jq -r '.branch' <<< "$spec")
		if [[ -z "$branch" ]]; then
			branch=$(remote_default_branch "$url")
			[[ -n "$branch" ]] || die "could not resolve default branch of ${url}"
		fi

		log "fetching ${repo} (${branch})…"
		git fetch --quiet --no-tags "$url" "refs/heads/${branch}" \
			|| die "failed to fetch ${branch} from ${url}"
		local remote_sha merge_base behind ahead
		remote_sha=$(git rev-parse FETCH_HEAD)
		if ! merge_base=$(git merge-base "$base_sha" "$remote_sha" 2> /dev/null); then
			warn "${repo} shares no history with this repository, skipping"
			continue
		fi
		behind=$(git rev-list --count "${merge_base}..${remote_sha}")
		ahead=$(git rev-list --count "${merge_base}..${base_sha}")

		# The GitHub parent (auto-detected), or an explicit `parent: true` in
		# config — only the parent is eligible for fast-forwarding.
		local is_parent
		is_parent=$(jq -r '.parent' <<< "$spec")
		[[ -n "$parent" && "$repo" == "$parent" ]] && is_parent='true'

		# An ignore rule is "active" when the unwanted commit is inside the
		# range this sync would bring in — which rules out fast-forwarding.
		local ignore_active='false' ignore_sha
		while IFS= read -r ignore_sha; do
			[[ -n "$ignore_sha" ]] || continue
			if git cat-file -e "${ignore_sha}^{commit}" 2> /dev/null \
				&& is_ancestor "$ignore_sha" "$remote_sha" \
				&& ! is_ancestor "$ignore_sha" "$merge_base"; then
				ignore_active='true'
			fi
		done < <(config_get '(.ignore // [])[].sha')

		local action='sync'
		if [[ "$behind" -eq 0 ]]; then
			action='none'
		elif [[ "$ahead" -eq 0 && "$is_parent" == 'true' && "$ignore_active" == 'false' ]]; then
			if [[ "$ff_mode" == 'auto' ]]; then action='ff'; else action='ff-issue'; fi
		fi

		# Rebase-mode tag analysis: the newest tag reachable from the base
		# branch freezes history up to itself.
		local frozen_tag='' rebase_mode=''
		if [[ "$strategy" == 'rebase' && "$action" == 'sync' ]]; then
			frozen_tag=$(git describe --tags --abbrev=0 "$base_sha" 2> /dev/null || true)
			if [[ -z "$frozen_tag" ]] || is_ancestor "refs/tags/${frozen_tag}" "$merge_base"; then
				rebase_mode='pure' # tag (if any) lives in shared history — untouched by a rebase
				frozen_tag=''
			else
				rebase_mode='frozen' # tag contains fork-specific commits — preserve up to it
			fi
		fi

		local sync_branch remote_branch_sha='' pr_state
		sync_branch="${FT_BRANCH_PREFIX}$(sanitize_ref "$repo")"
		remote_branch_sha=$(git ls-remote origin "refs/heads/${sync_branch}" 2> /dev/null | cut -f1 || true)
		pr_state=$(pr_state_for_branch "$sync_branch")

		local entry
		entry=$(jq -cn \
			--arg repo "$repo" --arg url "$url" --arg branch "$branch" \
			--arg remote_sha "$remote_sha" --arg merge_base "$merge_base" \
			--argjson behind "$behind" --argjson ahead "$ahead" \
			--argjson is_parent "$is_parent" --argjson ignore_active "$ignore_active" \
			--arg action "$action" --arg sync_branch "$sync_branch" \
			--arg frozen_tag "$frozen_tag" --arg rebase_mode "$rebase_mode" \
			--arg remote_branch_sha "$remote_branch_sha" --argjson pr "$pr_state" \
			'{repo: $repo, url: $url, branch: $branch, remote_sha: $remote_sha,
			  merge_base: $merge_base, behind: $behind, ahead: $ahead,
			  is_parent: $is_parent, ignore_active: $ignore_active, action: $action,
			  sync_branch: $sync_branch, frozen_tag: $frozen_tag,
			  rebase_mode: $rebase_mode, remote_branch_sha: $remote_branch_sha,
			  pr: $pr}')
		entries=$(jq -c --argjson e "$entry" '. + [$e]' <<< "$entries")
		log "${repo}: behind=${behind} ahead=${ahead} action=${action}${rebase_mode:+ rebase_mode=${rebase_mode}}"
	done < <(jq -c '.[]' <<< "$upstream_specs")

	jq -n \
		--arg base_branch "$base_branch" --arg base_sha "$base_sha" \
		--arg strategy "$strategy" --arg ff_mode "$ff_mode" \
		--argjson upstreams "$entries" \
		'{base_branch: $base_branch, base_sha: $base_sha, strategy: $strategy,
		  ff_mode: $ff_mode, upstreams: $upstreams}' > "$FT_STATE_FILE"

	local ff_count sync_count
	ff_count=$(jq -r '[.upstreams[] | select(.action == "ff" or .action == "ff-issue")] | length' "$FT_STATE_FILE")
	sync_count=$(jq -r '[.upstreams[] | select(.action == "sync")] | length' "$FT_STATE_FILE")
	set_output has_work "$([[ $((ff_count + sync_count)) -gt 0 ]] && echo true || echo false)"
	set_output needs_ff "$([[ "$ff_count" -gt 0 ]] && echo true || echo false)"
	set_output needs_sync "$([[ "$sync_count" -gt 0 ]] && echo true || echo false)"
	log "detection complete: ${ff_count} fast-forward, ${sync_count} sync"
}

main "$@"
