#!/usr/bin/env bash
# Shared helpers for fork-tender scripts. Source this file, don't execute it.
# shellcheck disable=SC2034 # constants here are consumed by sourcing scripts

set -euo pipefail

FT_STATE_DIR="${FT_STATE_DIR:-${RUNNER_TEMP:-/tmp}/fork-tender}"
FT_STATE_FILE="$FT_STATE_DIR/state.json"
FT_CONFIG_FILE="$FT_STATE_DIR/config.json"
FT_RESULTS_FILE="$FT_STATE_DIR/results.json"
FT_PROMPT_FILE="$FT_STATE_DIR/prompt.md"
FT_TRAILER_KEY="Fork-Tender"
FT_TRAILER="${FT_TRAILER_KEY}: v1"
FT_LABEL="fork-tender"
FT_LABEL_BROKEN="fork-tender:broken"
FT_BRANCH_PREFIX="fork-tender/"

# Built-in protected paths: agent configuration that upstream must never
# control (prompt-injection vector), plus workflow files that most tokens
# can't push anyway. Extended by the config's `protected` list.
FT_PROTECTED_DEFAULTS=(
	'CLAUDE.md'
	'CLAUDE.local.md'
	'.claude'
	'.claude.json'
	'.mcp.json'
	'.cursor'
	'.cursorrules'
	'.github/fork-tender.yml'
	'.github/workflows'
)

# All diagnostics go to stderr: many helpers are called inside command
# substitutions, and anything on stdout would corrupt their return values.
log() { printf '[fork-tender] %s\n' "$*" >&2; }
warn() { printf '::warning::[fork-tender] %s\n' "$*" >&2; }
die() {
	printf '::error::[fork-tender] %s\n' "$*" >&2
	exit 1
}

# True when running outside GitHub (local fixture tests): skips all gh calls.
skip_gh() { [[ "${FT_SKIP_GH:-}" == '1' ]]; }

dry_run() { [[ "${FT_DRY_RUN:-}" == 'true' ]]; }

set_output() {
	local name=$1 value=$2
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
	fi
	log "output: ${name}=${value}"
}

set_output_from_file() {
	local name=$1 file=$2
	# Random heredoc delimiter: file contents may embed untrusted upstream
	# text, and a predictable delimiter would allow output injection.
	local delim="FT_OUTPUT_EOF_${RANDOM}${RANDOM}${RANDOM}"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			printf '%s<<%s\n' "$name" "$delim"
			cat "$file"
			printf '\n%s\n' "$delim"
		} >> "$GITHUB_OUTPUT"
	fi
	log "output: ${name}=<$(wc -c < "$file") bytes>"
}

ensure_git_identity() {
	git config user.name > /dev/null 2>&1 || git config user.name 'fork-tender'
	git config user.email > /dev/null 2>&1 || git config user.email 'fork-tender@users.noreply.github.com'
}

# Authenticate git-over-HTTPS to github.com with whatever token this step
# holds, so fetches and pushes work even when the checkout used
# persist-credentials: false (or the repo is private).
setup_git_auth() {
	local token="${FT_PUSH_TOKEN:-${GH_TOKEN:-}}"
	if [[ -n "$token" ]] && ! skip_gh; then
		local header
		header=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')
		git config --local --replace-all 'http.https://github.com/.extraheader' \
			"AUTHORIZATION: basic ${header}"
		trap 'git config --local --unset-all "http.https://github.com/.extraheader" 2>/dev/null || true' EXIT
	fi
}

config_get() { jq -r "$1" "$FT_CONFIG_FILE"; }

# Turn "owner/repo" into a string safe for use in a branch name.
sanitize_ref() { printf '%s' "$1" | sed 's|[^A-Za-z0-9._-]|-|g'; }

is_ancestor() { git merge-base --is-ancestor "$1" "$2" 2> /dev/null; }

# The default branch of this checkout, established by detect.sh.
base_branch() { jq -r '.base_branch' "$FT_STATE_FILE"; }
base_sha() { git rev-parse "refs/heads/$(base_branch)"; }

# All protected paths: built-in defaults plus the config's `protected` list.
protected_paths() {
	printf '%s\n' "${FT_PROTECTED_DEFAULTS[@]}"
	config_get '(.protected // [])[]'
}

# Reset every protected path on the current branch to exactly its state at
# $1 (a commit-ish, normally the base branch tip), including deletion when
# absent there. Stages the result. Safe to call mid-merge.
restore_protected_paths() {
	local ref=$1 path
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		if git cat-file -e "${ref}:${path}" 2> /dev/null; then
			git checkout --no-overlay "$ref" -- "$path" 2> /dev/null || git checkout "$ref" -- "$path"
		elif [[ -e "$path" ]] && git ls-tree -r --name-only HEAD -- "$path" | grep -q .; then
			# Path exists in the merge result but not in ours: our deletion (or
			# never-had-it) wins.
			git rm -r -q --force -- "$path" 2> /dev/null || rm -rf -- "${path:?}"
		fi
		git add -A -- "$path" 2> /dev/null || true
	done < <(protected_paths)
}

# Emit `git log --oneline` style lines for a range, with content defanged
# for embedding in prompts/issues: @-mentions disarmed and any HTML comment
# or fence-delimiter lookalikes stripped.
defanged_log() {
	local range=$1 limit=${2:-200}
	git log --no-decorate --format='%h %s (%an)' "$range" \
		| head -n "$limit" \
		| sed -e 's/@/@\xE2\x80\x8B/g' -e 's/<!--//g' -e 's/-->//g' -e 's/```/` ` `/g'
}
