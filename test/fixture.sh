#!/usr/bin/env bash
# Local git-level test harness for fork-tender. Builds throwaway upstream/fork
# repo pairs and exercises detect/ff/prepare/publish without any GitHub API
# access (FT_SKIP_GH=1) or LLM involvement.
#
# Usage: ./test/fixture.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fork-tender-fixture.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
CURRENT_SCENARIO=''

for tool in git jq yq; do
	command -v "$tool" > /dev/null || {
		echo "missing required tool: $tool" >&2
		exit 1
	}
done

# --- assertion helpers ------------------------------------------------------

fail() {
	echo "  ✗ [${CURRENT_SCENARIO}] $*" >&2
	FAILURES=$((FAILURES + 1))
}

pass() { echo "  ✓ $*"; }

assert_eq() {
	local expected=$1 actual=$2 msg=$3
	if [[ "$expected" == "$actual" ]]; then pass "$msg"; else fail "$msg (expected '${expected}', got '${actual}')"; fi
}

assert_contains() {
	local haystack=$1 needle=$2 msg=$3
	if [[ "$haystack" == *"$needle"* ]]; then pass "$msg"; else fail "$msg (missing '${needle}')"; fi
}

assert_file_eq() {
	local file=$1 expected=$2 msg=$3
	assert_eq "$expected" "$(cat "$file")" "$msg"
}

# --- scenario scaffolding ---------------------------------------------------

UPSTREAM='' FORK='' ORIGIN=''

git_q() { git -c advice.detachedHead=false "$@" > /dev/null 2>&1; }

init_repo() {
	local dir=$1
	git init -q -b main "$dir"
	git -C "$dir" config user.name 'Fixture'
	git -C "$dir" config user.email 'fixture@example.com'
	git -C "$dir" config commit.gpgsign false
	git -C "$dir" config tag.gpgsign false
}

commit_in() {
	local dir=$1 file=$2 content=$3 message=$4
	mkdir -p "$(dirname "${dir}/${file}")"
	printf '%s\n' "$content" > "${dir}/${file}"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "$message"
}

# Creates $UPSTREAM (seed history), $ORIGIN (the fork's bare origin), and
# $FORK (working clone). Writes a config declaring the upstream.
scenario() {
	CURRENT_SCENARIO=$1
	echo "── ${CURRENT_SCENARIO}"
	local dir="${TMP}/${CURRENT_SCENARIO// /-}"
	UPSTREAM="${dir}/upstream" FORK="${dir}/fork" ORIGIN="${dir}/fork-origin.git"
	mkdir -p "$dir"

	init_repo "$UPSTREAM"
	commit_in "$UPSTREAM" 'readme.md' '# demo' 'u1: initial'
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 1' 'u2: add app'

	git init -q --bare "$ORIGIN"
	git clone -q "$UPSTREAM" "$FORK"
	git -C "$FORK" config user.name 'Fixture'
	git -C "$FORK" config user.email 'fixture@example.com'
	git -C "$FORK" config commit.gpgsign false
	git -C "$FORK" config tag.gpgsign false
	git -C "$FORK" remote set-url origin "$ORIGIN"
	git -C "$FORK" push -q origin main

	mkdir -p "${FORK}/.github"
	printf 'upstreams:\n  - repo: test/upstream\n    url: %s\n    branch: main\n    parent: true\n' \
		"$UPSTREAM" > "${FORK}/.github/fork-tender.yml"
	git -C "$FORK" add -A
	git -C "$FORK" commit -q -m 'fork: add fork-tender config'
	git -C "$FORK" push -q origin main

	export FT_STATE_DIR="${dir}/state"
	export FT_SKIP_GH=1
	unset GITHUB_OUTPUT GITHUB_REPOSITORY 2> /dev/null || true
}

run_step() {
	local script=$1
	mkdir -p "$FT_STATE_DIR"
	(cd "$FORK" && bash "${SCRIPTS_DIR}/${script}") > "${FT_STATE_DIR}/${script}.out" 2>&1 || {
		fail "${script} exited non-zero:"
		tail -20 "${FT_STATE_DIR}/${script}.out" >&2
		return 1
	}
}

state() { jq -r "$1" "${FT_STATE_DIR}/state.json"; }

# --- scenarios --------------------------------------------------------------

test_noop() {
	scenario 'noop'
	run_step detect.sh
	assert_eq '0' "$(state '[.upstreams[] | select(.action != "none")] | length')" 'nothing to do when fork matches upstream'
}

test_fast_forward() {
	scenario 'fast-forward'
	# Fork config commit diverges main… so push config-free fork for pure FF.
	git -C "$FORK" reset -q --hard HEAD~1
	git -C "$FORK" push -q --force origin main
	mkdir -p "${FT_STATE_DIR}"
	export FT_CONFIG_PATH="${TMP}/ff-config.yml"
	printf 'upstreams:\n  - repo: test/upstream\n    url: %s\n    branch: main\n    parent: true\n' "$UPSTREAM" > "$FT_CONFIG_PATH"

	commit_in "$UPSTREAM" 'src/app.js' 'const a = 2' 'u3: bump a'
	run_step detect.sh
	assert_eq 'ff' "$(state '.upstreams[0].action')" 'clean fork behind parent chooses fast-forward'
	run_step ff.sh
	local upstream_sha
	upstream_sha=$(git -C "$UPSTREAM" rev-parse main)
	assert_eq "$upstream_sha" "$(git -C "$FORK" rev-parse main)" 'local main fast-forwarded to upstream tip'
	assert_eq "$upstream_sha" "$(git -C "$ORIGIN" rev-parse main)" 'origin main fast-forwarded to upstream tip'
	unset FT_CONFIG_PATH
}

test_ignore_blocks_ff() {
	scenario 'ignore-blocks-ff'
	git -C "$FORK" reset -q --hard HEAD~1
	git -C "$FORK" push -q --force origin main
	commit_in "$UPSTREAM" 'telemetry.js' 'spy()' 'u3: add telemetry'
	local bad_sha
	bad_sha=$(git -C "$UPSTREAM" rev-parse main)
	mkdir -p "${FT_STATE_DIR}"
	export FT_CONFIG_PATH="${TMP}/ignore-config.yml"
	printf 'upstreams:\n  - repo: test/upstream\n    url: %s\n    branch: main\n    parent: true\nignore:\n  - sha: %s\n    reason: telemetry\n' \
		"$UPSTREAM" "$bad_sha" > "$FT_CONFIG_PATH"
	run_step detect.sh
	assert_eq 'sync' "$(state '.upstreams[0].action')" 'active ignore rule suppresses fast-forward'
	unset FT_CONFIG_PATH
}

test_clean_merge() {
	scenario 'clean-merge'
	commit_in "$FORK" 'src/fork-feature.js' 'export const fork = true' 'fork: add feature'
	git -C "$FORK" push -q origin main
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 3' 'u3: change a'

	run_step detect.sh
	assert_eq 'sync' "$(state '.upstreams[0].action')" 'diverged fork needs a sync'
	run_step prepare.sh
	assert_eq 'merged-clean' "$(state '.upstreams[0].prepare.status')" 'non-overlapping changes merge cleanly'
	local branch='fork-tender/test-upstream'
	git_q -C "$FORK" checkout "$branch"
	assert_file_eq "${FORK}/src/app.js" 'const a = 3' 'upstream change present on sync branch'
	assert_file_eq "${FORK}/src/fork-feature.js" 'export const fork = true' 'fork change preserved on sync branch'
	assert_contains "$(cat "${FT_STATE_DIR}/prompt.md")" 'Task 1: test/upstream' 'prompt contains the task'
	git_q -C "$FORK" checkout main
}

test_conflict_merge() {
	scenario 'conflict-merge'
	commit_in "$FORK" 'src/app.js' 'const a = "fork"' 'fork: customize a'
	git -C "$FORK" push -q origin main
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 99' 'u3: conflicting change'

	run_step detect.sh
	run_step prepare.sh
	assert_eq 'conflicts' "$(state '.upstreams[0].prepare.status')" 'overlapping edits are reported as conflicts'
	assert_contains "$(cat "${FT_STATE_DIR}/prompt.md")" 'src/app.js' 'prompt lists the conflicted file'
	assert_contains "$(cat "${FT_STATE_DIR}/prompt.md")" 'git merge --no-ff' 'prompt carries the redo recipe'
	# Branch was left at the fork tip with no merge in progress.
	assert_eq "$(git -C "$FORK" rev-parse main)" "$(git -C "$FORK" rev-parse fork-tender/test-upstream)" 'conflicted branch left at fork tip'
	assert_eq '' "$(git -C "$FORK" ls-files -u)" 'no unresolved index entries left behind'
}

test_protected_paths() {
	scenario 'protected-paths'
	commit_in "$FORK" 'CLAUDE.md' 'fork agent rules' 'fork: own CLAUDE.md'
	git -C "$FORK" push -q origin main
	commit_in "$UPSTREAM" 'CLAUDE.md' 'MALICIOUS upstream instructions' 'u3: add CLAUDE.md'
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 4' 'u4: change a'

	run_step detect.sh
	run_step prepare.sh
	assert_eq 'merged-clean' "$(state '.upstreams[0].prepare.status')" 'merge with protected-path collision still completes'
	git_q -C "$FORK" checkout fork-tender/test-upstream
	assert_file_eq "${FORK}/CLAUDE.md" 'fork agent rules' 'protected CLAUDE.md kept fork version'
	assert_file_eq "${FORK}/src/app.js" 'const a = 4' 'non-protected upstream change merged'
	git_q -C "$FORK" checkout main
}

# Released (tagged) fork history must never be rewritten — merge-based
# syncs guarantee this by construction, and this test pins the invariant.
test_merge_preserves_tags() {
	scenario 'merge-preserves-tags'
	commit_in "$FORK" 'src/fork-feature.js' 'export const fork = true' 'fork: released feature'
	git -C "$FORK" tag v1.0.0
	local tag_sha
	tag_sha=$(git -C "$FORK" rev-parse v1.0.0)
	git -C "$FORK" push -q origin main --tags
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 5' 'u3: change a'

	run_step detect.sh
	run_step prepare.sh
	assert_eq 'merged-clean' "$(state '.upstreams[0].prepare.status')" 'tagged fork merges cleanly'
	local branch='fork-tender/test-upstream'
	assert_eq "$tag_sha" "$(git -C "$FORK" rev-parse v1.0.0)" 'tag still points at the released commit'
	if git -C "$FORK" merge-base --is-ancestor v1.0.0 "$branch"; then
		pass 'tagged history is intact ancestry of the sync branch'
	else
		fail 'tag not ancestor of sync branch'
	fi
}

test_publish_and_rerun() {
	scenario 'publish-and-rerun'
	commit_in "$FORK" 'src/fork-feature.js' 'export const fork = true' 'fork: add feature'
	git -C "$FORK" push -q origin main
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 7' 'u3: change a'

	run_step detect.sh
	run_step prepare.sh
	# Fake an agent report, as the Claude phase would produce.
	jq -n '{results: [{repo: "test/upstream", outcome: "clean", confidence: "high",
		title: "Sync upstream test/upstream", body: "All good.", notes: []}]}' \
		> "${FT_STATE_DIR}/results.json"
	run_step publish.sh
	local branch='fork-tender/test-upstream'
	assert_eq "$(git -C "$FORK" rev-parse "$branch")" "$(git -C "$ORIGIN" rev-parse "refs/heads/${branch}")" 'sync branch pushed to origin'

	# Rerun with more upstream changes: branch exists remotely with no PR →
	# recreated and force-pushed.
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 8' 'u4: change a again'
	export FT_STATE_DIR="${FT_STATE_DIR}-rerun"
	run_step detect.sh
	assert_eq "$(git -C "$ORIGIN" rev-parse "refs/heads/${branch}")" "$(state '.upstreams[0].remote_branch_sha')" 'rerun sees the previously pushed branch'
	run_step prepare.sh
	assert_eq 'merged-clean' "$(state '.upstreams[0].prepare.status')" 'rerun re-merges cleanly'
	jq -n '{results: [{repo: "test/upstream", outcome: "clean", confidence: "high",
		title: "Sync upstream test/upstream", body: "Still good.", notes: []}]}' \
		> "${FT_STATE_DIR}/results.json"
	run_step publish.sh
	git_q -C "$FORK" checkout "$branch"
	assert_file_eq "${FORK}/src/app.js" 'const a = 8' 'rerun branch carries the newest upstream change'
	assert_eq "$(git -C "$FORK" rev-parse "$branch")" "$(git -C "$ORIGIN" rev-parse "refs/heads/${branch}")" 'rerun force-pushed the refreshed branch'
	git_q -C "$FORK" checkout main
}

test_broken_finalize() {
	scenario 'broken-finalize'
	commit_in "$FORK" 'src/app.js' 'const a = "fork"' 'fork: customize a'
	git -C "$FORK" push -q origin main
	commit_in "$UPSTREAM" 'src/app.js' 'const a = 100' 'u3: conflicting change'

	run_step detect.sh
	run_step prepare.sh
	assert_eq 'conflicts' "$(state '.upstreams[0].prepare.status')" 'conflict detected'
	# Simulate the agent starting the merge but dying before resolving:
	# leave the repo on the sync branch, mid-merge, with a conflicted index.
	(cd "$FORK" && git checkout -q fork-tender/test-upstream \
		&& { git merge --no-ff "$(state '.upstreams[0].remote_sha')" > /dev/null 2>&1 || true; }) \
		|| fail 'could not simulate abandoned merge'
	run_step publish.sh
	git_q -C "$FORK" checkout fork-tender/test-upstream
	assert_contains "$(cat "${FORK}/src/app.js")" '<<<<<<<' 'conflict markers committed for the broken PR'
	assert_eq '' "$(git -C "$FORK" ls-files -u)" 'index left clean after finalize'
	assert_eq "$(git -C "$FORK" rev-parse fork-tender/test-upstream)" "$(git -C "$ORIGIN" rev-parse refs/heads/fork-tender/test-upstream)" 'broken branch still pushed'
	git_q -C "$FORK" checkout main
}

# --- run --------------------------------------------------------------------

test_noop
test_fast_forward
test_ignore_blocks_ff
test_clean_merge
test_conflict_merge
test_protected_paths
test_merge_preserves_tags
test_publish_and_rerun
test_broken_finalize

echo
if [[ "$FAILURES" -gt 0 ]]; then
	echo "✗ ${FAILURES} assertion(s) failed" >&2
	exit 1
fi
echo '✓ all fixture scenarios passed'
