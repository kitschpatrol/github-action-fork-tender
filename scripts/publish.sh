#!/usr/bin/env bash
# Phase 5: deterministic publication. Finalizes each sync branch (backstopping
# whatever state the agent left), enforces protected paths, pushes, and
# creates/updates pull requests. All GitHub writes happen here, not in the
# agent session.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_labels() {
	skip_gh && return 0
	gh label create "$FT_LABEL" --color '0e8a16' \
		--description 'Automated upstream sync by fork-tender' --force > /dev/null 2>&1 || true
	gh label create "$FT_LABEL_BROKEN" --color 'd93f0b' \
		--description 'Upstream sync needs human conflict resolution' --force > /dev/null 2>&1 || true
}

# Read the agent's report entry for a repo; synthesize a fallback if absent.
result_for() {
	local repo=$1 behind=$2
	local fallback
	fallback=$(jq -cn --arg repo "$repo" --arg title "Sync upstream ${repo} (${behind} new commits)" \
		'{repo: $repo, outcome: "partial", confidence: "low", title: $title,
		  body: "The agent did not produce a report for this sync. Review the branch contents directly.",
		  notes: ["missing agent report"]}')
	if [[ -f "$FT_RESULTS_FILE" ]] && jq -e '.results | type == "array"' "$FT_RESULTS_FILE" > /dev/null 2>&1; then
		jq -c --arg repo "$repo" --argjson fallback "$fallback" \
			'([.results[] | select(.repo == $repo)][0]) // $fallback' "$FT_RESULTS_FILE"
	else
		echo "$fallback"
	fi
}

# Commit whatever half-finished state the agent may have left, so the branch
# is always publishable. Echoes 'broken' if it had to intervene, else ''.
finalize_branch() {
	local git_dir
	git_dir=$(git rev-parse --git-dir)
	if [[ -d "${git_dir}/rebase-merge" || -d "${git_dir}/rebase-apply" ]]; then
		git rebase --abort || true
		echo 'broken'
		return 0
	fi
	if git ls-files -u | grep -q . || [[ -f "${git_dir}/MERGE_HEAD" ]]; then
		git add -A
		git commit -q --no-verify \
			-m 'Unresolved upstream sync (conflict markers committed)' -m "$FT_TRAILER"
		echo 'broken'
		return 0
	fi
	if ! git diff --quiet || ! git diff --cached --quiet; then
		git add -A
		git commit -q --no-verify -m 'Uncommitted sync work' -m "$FT_TRAILER"
	fi
	echo ''
}

sanitize_markdown() { sed -e 's/<!--//g' -e 's/-->//g' | head -c 60000; }

build_pr_body() {
	local entry=$1 result=$2 head_sha=$3 verify_display=$4
	local repo remote_sha merge_base behind upstream_branch outcome confidence strategy
	repo=$(jq -r '.repo' <<< "$entry")
	remote_sha=$(jq -r '.remote_sha' <<< "$entry")
	merge_base=$(jq -r '.merge_base' <<< "$entry")
	behind=$(jq -r '.behind' <<< "$entry")
	upstream_branch=$(jq -r '.branch' <<< "$entry")
	outcome=$(jq -r '.outcome' <<< "$result")
	confidence=$(jq -r '.confidence // "low"' <<< "$result")
	strategy=$(jq -r '.strategy' "$FT_STATE_FILE")

	jq -r '.body // ""' <<< "$result" | sanitize_markdown
	printf '\n\n---\n\n'
	printf '**%s new commit(s)** from [`%s`](https://github.com/%s/tree/%s) · [upstream compare](https://github.com/%s/compare/%s...%s)\n\n' \
		"$behind" "$repo" "$repo" "$upstream_branch" "$repo" "${merge_base:0:12}" "${remote_sha:0:12}"
	printf '%s\n\n' "$verify_display"
	if [[ "$strategy" == 'rebase' ]]; then
		local sync_branch base
		sync_branch=$(jq -r '.sync_branch' <<< "$entry")
		base=$(base_branch)
		printf '### Landing this PR\n\n'
		printf 'This branch rewrites history relative to `%s`, so the GitHub merge button cannot land it. After review, land it manually:\n\n' "$base"
		printf '```sh\ngit fetch origin\ngit checkout %s\ngit reset --hard origin/%s\ngit push --force-with-lease origin %s\n```\n\nThen close this PR.\n\n' \
			"$base" "$sync_branch" "$base"
	fi
	printf '<sub>Automated by fork-tender · outcome: `%s` · confidence: `%s`</sub>\n\n' "$outcome" "$confidence"
	printf '<!-- fork-tender-upstream: %s -->\n<!-- fork-tender-head: %s -->\n' "$remote_sha" "$head_sha"
}

comment_once() {
	local pr_number=$1 marker=$2 body=$3
	skip_gh && return 0
	if gh pr view "$pr_number" --json comments --jq '.comments[].body' 2> /dev/null | grep -qF "$marker"; then
		return 0
	fi
	gh pr comment "$pr_number" --body "$body
$marker" > /dev/null
}

publish_skip_outcome() {
	local entry=$1 result=$2
	local repo sync_branch pr_number pr_state
	repo=$(jq -r '.repo' <<< "$entry")
	sync_branch=$(jq -r '.sync_branch' <<< "$entry")
	pr_number=$(jq -r '.pr.number // ""' <<< "$entry")
	pr_state=$(jq -r '.pr.state // ""' <<< "$entry")

	log "${repo}: agent recommends skipping this sync"
	if dry_run || skip_gh; then
		return 0
	fi
	local body_file
	body_file="${FT_STATE_DIR}/skip-$(sanitize_ref "$repo").md"
	{
		printf 'Fork Tender evaluated the new upstream commits from `%s` and recommends **not syncing right now**:\n\n' "$repo"
		jq -r '.body // "(no reasoning provided)"' <<< "$result" | sanitize_markdown
		printf '\n\n<!-- fork-tender-upstream: %s -->\n' "$(jq -r '.remote_sha' <<< "$entry")"
	} > "$body_file"
	if [[ "$pr_state" == 'OPEN' && -n "$pr_number" ]]; then
		gh pr close "$pr_number" --comment "$(cat "$body_file")" --delete-branch > /dev/null || true
	else
		git push origin --delete "$sync_branch" > /dev/null 2>&1 || true
		gh issue create --title "Fork Tender: sync of ${repo} not advisable" \
			--label "$FT_LABEL" --body-file "$body_file" > /dev/null || warn "could not open skip-advice issue for ${repo}"
	fi
}

publish_branch() {
	local entry=$1 status=$2
	local repo sync_branch behind remote_branch_sha pr_number pr_state
	repo=$(jq -r '.repo' <<< "$entry")
	sync_branch=$(jq -r '.sync_branch' <<< "$entry")
	behind=$(jq -r '.behind' <<< "$entry")
	remote_branch_sha=$(jq -r '.remote_branch_sha' <<< "$entry")
	pr_number=$(jq -r '.pr.number // ""' <<< "$entry")
	pr_state=$(jq -r '.pr.state // ""' <<< "$entry")

	git checkout -q "$sync_branch"
	local forced_broken result outcome
	forced_broken=$(finalize_branch)
	restore_protected_paths "$(base_sha)"
	if ! git diff --cached --quiet; then
		git commit -q --no-verify -m 'Restore protected paths' -m "$FT_TRAILER"
	fi

	result=$(result_for "$repo" "$behind")
	outcome=$(jq -r '.outcome // "partial"' <<< "$result")
	if [[ -n "$forced_broken" ]]; then
		outcome='broken'
		result=$(jq -c '.outcome = "broken" | .notes += ["publish: agent left the branch unfinished; conflict markers or partial state were committed as-is"]' <<< "$result")
	fi

	if [[ "$outcome" == 'skip' ]]; then
		git checkout -q "$(base_branch)"
		publish_skip_outcome "$entry" "$result"
		echo "$outcome"
		return 0
	fi

	if [[ "$(git rev-parse HEAD)" == "$(base_sha)" ]]; then
		log "${repo}: branch is identical to $(base_branch), nothing to publish"
		git checkout -q "$(base_branch)"
		echo 'empty'
		return 0
	fi

	local head_sha verify_display
	head_sha=$(git rev-parse HEAD)
	verify_display=$(verify_table "$entry")
	local body_file
	body_file="${FT_STATE_DIR}/pr-$(sanitize_ref "$repo").md"
	build_pr_body "$entry" "$result" "$head_sha" "$verify_display" > "$body_file"
	local title
	title=$(jq -r '.title // ""' <<< "$result" | tr -d '\n' | head -c 120)
	[[ -n "$title" ]] || title="Sync upstream ${repo} (${behind} new commits)"

	git checkout -q "$(base_branch)"
	if dry_run; then
		log "[dry-run] would push ${sync_branch} (${head_sha}) and open/update PR: ${title}"
		echo "$outcome"
		return 0
	fi

	if [[ -n "$remote_branch_sha" ]]; then
		git push --force-with-lease="refs/heads/${sync_branch}:${remote_branch_sha}" origin "$sync_branch"
	else
		git push origin "$sync_branch"
	fi

	if skip_gh; then
		echo "$outcome"
		return 0
	fi

	local draft_args=()
	[[ "$outcome" == 'partial' || "$outcome" == 'broken' ]] && draft_args=(--draft)
	local pr_url=''
	if [[ "$pr_state" == 'OPEN' && -n "$pr_number" ]]; then
		gh pr edit "$pr_number" --title "$title" --body-file "$body_file" > /dev/null
		if [[ "$outcome" == 'partial' || "$outcome" == 'broken' ]]; then
			gh pr ready "$pr_number" --undo > /dev/null 2>&1 || true
		fi
		pr_url=$(gh pr view "$pr_number" --json url --jq '.url')
		log "${repo}: updated PR ${pr_url}"
	else
		pr_url=$(gh pr create --head "$sync_branch" --base "$(base_branch)" \
			--title "$title" --body-file "$body_file" "${draft_args[@]}")
		pr_number=$(gh pr view "$pr_url" --json number --jq '.number')
		log "${repo}: opened PR ${pr_url}"
	fi
	gh pr edit "$pr_number" --add-label "$FT_LABEL" > /dev/null 2>&1 || true
	if [[ "$outcome" == 'broken' ]]; then
		gh pr edit "$pr_number" --add-label "$FT_LABEL_BROKEN" > /dev/null 2>&1 || true
	else
		gh pr edit "$pr_number" --remove-label "$FT_LABEL_BROKEN" > /dev/null 2>&1 || true
	fi
	if [[ -n "$pr_url" ]]; then
		printf '%s\n' "$pr_url" >> "${FT_STATE_DIR}/pr-urls.txt"
	fi
	echo "$outcome"
}

verify_table() {
	local entry=$1 baseline branch_verify
	baseline=$(jq -r '.baseline_verify // "skipped"' "$FT_STATE_FILE")
	branch_verify=$(jq -r '.prepare.verify // "skipped"' <<< "$entry")
	printf '| Verification | Result |\n|---|---|\n| Baseline (`%s`) | %s |\n| Mechanical pass on this branch | %s |\n\nSee the report above for post-resolution verification.' \
		"$(base_branch)" "$baseline" "$branch_verify"
}

main() {
	[[ -f "$FT_STATE_FILE" ]] || die 'state file missing: run detect.sh first'
	ensure_git_identity
	setup_git_auth
	dry_run || ensure_labels
	: > "${FT_STATE_DIR}/pr-urls.txt"

	local summary_file="${FT_STATE_DIR}/summary.md" outcomes='{}'
	printf '### Fork Tender\n\n| Upstream | Action | Outcome |\n|---|---|---|\n' > "$summary_file"

	local entry
	while IFS= read -r entry; do
		local repo action status outcome=''
		repo=$(jq -r '.repo' <<< "$entry")
		action=$(jq -r '.action' <<< "$entry")
		status=$(jq -r '.prepare.status // ""' <<< "$entry")

		case "$action" in
			none) outcome='up-to-date' ;;
			ff) outcome='fast-forwarded' ;;
			ff-issue) outcome='issue-notified' ;;
			sync)
				case "$status" in
					skipped-human)
						outcome='skipped-human-commits'
						local pr_number
						pr_number=$(jq -r '.pr.number // ""' <<< "$entry")
						if [[ -n "$pr_number" ]] && ! dry_run; then
							comment_once "$pr_number" \
								"<!-- fork-tender-skip: $(jq -r '.remote_branch_sha' <<< "$entry") -->" \
								'Fork Tender: this branch has commits it did not push, so this run left the PR untouched. Close the PR or merge your changes to let future runs refresh it.'
						fi
						;;
					declined) outcome='declined-previously' ;;
					empty) outcome='empty' ;;
					*) outcome=$(publish_branch "$entry" "$status") ;;
				esac
				;;
		esac
		printf '| `%s` | %s | %s |\n' "$repo" "$action" "$outcome" >> "$summary_file"
		outcomes=$(jq -c --arg repo "$repo" --arg outcome "$outcome" '. + {($repo): $outcome}' <<< "$outcomes")
	done < <(jq -c '.upstreams[]' "$FT_STATE_FILE")

	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		cat "$summary_file" >> "$GITHUB_STEP_SUMMARY"
	fi
	set_output outcome "$outcomes"
	set_output_from_file pr-urls "${FT_STATE_DIR}/pr-urls.txt"
	log "publish complete: ${outcomes}"
}

main "$@"
