#!/usr/bin/env bash
# Phase 2: handle upstreams that can fast-forward. Runs before any merge work
# so subsequent sync branches build on the updated base. Deterministic — the
# LLM is never in this write path.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ISSUE_TITLE_PREFIX='Fork Tender: upstream sync available'

fast_forward() {
	local repo=$1 remote_sha=$2 behind=$3
	local branch
	branch=$(base_branch)

	if dry_run; then
		log "[dry-run] would fast-forward ${branch} to ${repo}@${remote_sha} (${behind} commits)"
		return 0
	fi
	if skip_gh; then
		# Local/fixture mode: plain fast-forward push.
		git push origin "${remote_sha}:refs/heads/${branch}"
	else
		local merge_type
		merge_type=$(gh api --method POST "repos/${GITHUB_REPOSITORY}/merge-upstream" \
			-f branch="$branch" --jq '.merge_type') \
			|| die "merge-upstream API call failed for ${repo}; is this repository a GitHub fork of it?"
		[[ "$merge_type" == 'fast-forward' ]] \
			|| warn "expected a fast-forward but GitHub performed '${merge_type}'"
	fi

	# Bring the local checkout up to date so later phases build on the new tip.
	git fetch --quiet origin "refs/heads/${branch}"
	git merge --ff-only FETCH_HEAD
	log "fast-forwarded ${branch} to ${repo} (${behind} commits)"
}

notify_issue() {
	local repo=$1 remote_sha=$2 merge_base=$3 behind=$4 branch=$5
	local marker="<!-- fork-tender-upstream: ${remote_sha} -->"

	if dry_run || skip_gh; then
		log "[dry-run] would open/update sync notification issue for ${repo}"
		return 0
	fi

	local existing
	existing=$(gh issue list --label "$FT_LABEL" --state open \
		--search "in:title \"${ISSUE_TITLE_PREFIX}\"" \
		--json number,body --jq \
		--arg repo "$repo" '[.[] | select(.body | contains($repo))][0] // {}')
	if [[ $(jq -r '.body // ""' <<< "$existing") == *"$marker"* ]]; then
		log "notification issue for ${repo}@${remote_sha} already exists, skipping"
		return 0
	fi

	local body_file="${FT_STATE_DIR}/issue-${RANDOM}.md"
	{
		printf 'Upstream `%s` has **%s new commit(s)** and your fork can fast-forward cleanly.\n\n' "$repo" "$behind"
		printf 'Use the **Sync fork** button on GitHub, or run:\n\n'
		printf '```sh\ngit fetch %s %s\ngit checkout %s\ngit merge --ff-only FETCH_HEAD\ngit push origin %s\n```\n\n' \
			"https://github.com/${repo}.git" "$branch" "$(base_branch)" "$(base_branch)"
		printf '<details><summary>New upstream commits</summary>\n\n```text\n'
		defanged_log "${merge_base}..${remote_sha}"
		printf '```\n\n</details>\n\n%s\n' "$marker"
	} > "$body_file"

	gh label create "$FT_LABEL" --color '0e8a16' --description 'Automated upstream sync by fork-tender' --force > /dev/null 2>&1 || true
	local number
	number=$(jq -r '.number // empty' <<< "$existing")
	if [[ -n "$number" ]]; then
		gh issue edit "$number" --body-file "$body_file" > /dev/null
		log "updated notification issue #${number} for ${repo}"
	else
		gh issue create --title "${ISSUE_TITLE_PREFIX}: ${repo}" \
			--label "$FT_LABEL" --body-file "$body_file" > /dev/null
		log "opened notification issue for ${repo}"
	fi
}

main() {
	[[ -f "$FT_STATE_FILE" ]] || die 'state file missing: run detect.sh first'
	setup_git_auth
	local entry
	while IFS= read -r entry; do
		local repo action remote_sha merge_base behind upstream_branch
		repo=$(jq -r '.repo' <<< "$entry")
		action=$(jq -r '.action' <<< "$entry")
		remote_sha=$(jq -r '.remote_sha' <<< "$entry")
		merge_base=$(jq -r '.merge_base' <<< "$entry")
		behind=$(jq -r '.behind' <<< "$entry")
		upstream_branch=$(jq -r '.branch' <<< "$entry")
		case "$action" in
			ff) fast_forward "$repo" "$remote_sha" "$behind" ;;
			ff-issue) notify_issue "$repo" "$remote_sha" "$merge_base" "$behind" "$upstream_branch" ;;
		esac
	done < <(jq -c '.upstreams[] | select(.action == "ff" or .action == "ff-issue")' "$FT_STATE_FILE")
}

main "$@"
