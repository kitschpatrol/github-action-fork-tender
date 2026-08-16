<!-- title -->

# github-action-fork-tender

<!-- /title -->

<!-- badges -->

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/license/mit)
[![CI](https://github.com/kitschpatrol/github-action-fork-tender/actions/workflows/ci.yml/badge.svg)](https://github.com/kitschpatrol/github-action-fork-tender/actions/workflows/ci.yml)

<!-- /badges -->

<!-- description -->

**GitHub Action to keep your forks aligned with upstream.**

<!-- /description -->

> [!WARNING]
>
> **This project is under development. It should not be considered suitable for general use until a 2.0 release.**

Fork Tender runs on a schedule inside your forked GitHub repositories to detect new upstream commits, and integrates them while always preserving your fork's intent.

Boring cases are handled deterministically. Trickier cases go to an agent to fix any merge conflicts while preserving fork's functional changes. Intractable cases get a draft PR with committed conflict markers.

## How it works

Each run walks a ladder for each upstream repository:

1. **Nothing new** → exit.
2. **Pure fast-forward** — your fork has no unique commits: the "Sync fork" API fast-forwards your default branch directly. No LLM involved, upstream SHAs preserved. (Set `ff: issue` to get a notification issue instead.)
3. **Diverged** → a sync branch (`fork-tender/<owner>-<repo>`) is built mechanically: `git merge` with a shared [`rerere`](https://git-scm.com/docs/git-rerere) cache so previously-seen conflicts resolve for free, and agent-config files always restored to your version. The LLM then evaluates the changes, resolves any remaining conflicts (fork intent wins), applies your ignore rules, runs your verify command, and reports. A deterministic publish step pushes the branch and opens or refreshes the PR — the agent itself can never push or call the GitHub API.

Outcomes map to PR states: clean/resolved syncs are normal PRs, uncertain ones are drafts, unresolvable ones are drafts labeled `fork-tender:broken` with conflict markers committed for you to finish, and "don't take this" recommendations become issues instead of PRs.

## Usage

Two files are involved, both in your fork:

1. **A workflow** (required) at `.github/workflows/fork-tender.yml` — runs the action on a schedule. Shown below.
2. **A config file** (optional) at `.github/fork-tender.yml` — per-repo behavior like extra upstreams and ignore rules. See [Configuration](#configuration).

```yaml
# .github/workflows/fork-tender.yml
name: Fork Tender

on:
  workflow_dispatch: {}
  schedule:
    - cron: '0 6 * * 1'

permissions:
  contents: write
  pull-requests: write
  issues: write
  id-token: write

concurrency:
  group: fork-tender

jobs:
  tend:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0 # required: merges need full history
          persist-credentials: false

      - uses: kitschpatrol/github-action-fork-tender@v1
        env:
          # Bill your Claude subscription (token from `claude setup-token`):
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          # …or bill per-token with an API key instead:
          # ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Auth can also be passed as the explicit `anthropic-api-key` / `claude-code-oauth-token` inputs. Everything is taken at face value — no token-type detection — and the OAuth token wins if both kinds are set.

### Getting a token and setting the secret

To bill your Claude subscription (Pro/Max/Team/Enterprise), generate a long-lived OAuth token with the [Claude Code CLI](https://code.claude.com/docs/en/setup) — it opens a browser to authorize, then prints an `sk-ant-oat…` token:

```sh
claude setup-token
```

To bill per-token instead, create an API key (`sk-ant-api…`) in the [Anthropic Console](https://console.anthropic.com/settings/keys).

Then store the token as a repository secret under the matching name with the [GitHub CLI](https://cli.github.com) — you'll be prompted to paste it, which keeps it out of shell history:

```sh
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner>/<fork>
# or: gh secret set ANTHROPIC_API_KEY --repo <owner>/<fork>
```

Repeat per fork, or for organization-owned repos set it once for all of them with `gh secret set CLAUDE_CODE_OAUTH_TOKEN --org <org> --visibility all` (personal accounts don't have org secrets — set it on each repo).

### Inputs

| Input                     | Default                   | Description                                                                                                                                                                                    |
| ------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `anthropic-api-key`       | —                         | Anthropic API key. Optional when an `ANTHROPIC_API_KEY` env var is set on the action's step, as in the example above.                                                                          |
| `claude-code-oauth-token` | —                         | Claude subscription OAuth token from `claude setup-token`. Optional when a `CLAUDE_CODE_OAUTH_TOKEN` env var is set instead. The OAuth token is preferred when both kinds of auth are present. |
| `github-token`            | —                         | Token for pushes/PRs/issues. See [tokens](#tokens-and-ci-on-sync-prs).                                                                                                                         |
| `model`                   | `claude-opus-5`           | Claude model for evaluation and conflict resolution.                                                                                                                                           |
| `config-path`             | `.github/fork-tender.yml` | Location of the [config file](#configuration).                                                                                                                                                 |
| `max-turns`               | `100`                     | Agent turn budget for the Claude phase.                                                                                                                                                        |
| `allowed-bots`            | —                         | Pass through to claude-code-action when a bot account last edited the workflow's cron (GitHub attributes scheduled runs to that account).                                                      |
| `dry-run`                 | `false`                   | Detect and attempt merges locally, but never push, open PRs, or invoke Claude.                                                                                                                 |

### Outputs

| Output    | Description                                                                                                                                                                                                       |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `outcome` | JSON object mapping each upstream to its outcome: `up-to-date`, `fast-forwarded`, `issue-notified`, `clean`, `resolved`, `partial`, `broken`, `skip`, `empty`, `skipped-human-commits`, or `declined-previously`. |
| `pr-urls` | Newline-separated URLs of PRs created or updated.                                                                                                                                                                 |

## Configuration

Configuration lives in its own file at `.github/fork-tender.yml` — **not** inside the workflow above, and not under `workflows/` (same split as Dependabot's `.github/dependabot.yml`; relocate it with the `config-path` input). It's entirely optional: with no config file, the action auto-detects the fork's GitHub parent and uses defaults. Every key below is optional too.

```yaml
# .github/fork-tender.yml

# Upstreams to track. Omit entirely to auto-detect the GitHub parent.
upstreams:
  - repo: alex8088/electron-vite # GitHub parent — eligible for fast-forward
    parent: true
  - repo: desirecore/electron-vite # any other repo that shares history
    branch: main # optional, defaults to their default branch
    # url: https://example.com/mirror.git — optional explicit git URL
    #   (for upstreams not at github.com/<repo>.git)

# auto (default): fast-forward directly when your fork has no unique commits.
# issue: open a notification issue instead and leave the syncing to you.
ff: auto

# Run before and after each sync. The pre-sync baseline tells the agent
# whether a failure is pre-existing or something the sync broke. Killed
# after 30 minutes (override with an FT_VERIFY_TIMEOUT env var, seconds).
verify: pnpm install && pnpm build && pnpm test

# Extra Claude tool permissions, comma-separated — grant what your verify
# command needs to run; nothing else is accessible to the agent.
extra_allowed_tools: Bash(pnpm:*)

# Paths always kept at your fork's version, extending the built-in list
# (CLAUDE.md, CLAUDE.local.md, .claude/, .claude.json, .mcp.json, .cursor/,
# .cursorrules, .github/fork-tender.yml, .github/workflows/).
protected:
  - docs/fork-notes.md

# Upstream commits whose changes must never land in your fork. The agent
# reverts or edits them out on every sync and documents it in the PR.
ignore:
  - sha: 1a2b3c4d5e6f
    reason: telemetry — we never want this

# Free-text standing instructions for the agent.
guidance: |
  Never adopt upstream release workflows; ours are custom.
  Our public API in src/index.ts must remain backward compatible.
```

## Sync semantics

Diverged upstreams are always integrated with a **merge commit**. History is never rewritten, so your release tags — and everything you've published from them — are automatically safe, and every PR merges with the normal GitHub button. The cost is that your local patches stay interleaved in history rather than sitting on top as a clean stack; if you ever want to restack a fork, do that as a deliberate one-off (it requires force-pushing your default branch, which this action never does).

**Fast-forward** happens instead whenever your fork has no unique commits (parent upstream only). It uses GitHub's own merge-upstream API — the same thing as the "Sync fork" button — so upstream SHAs are preserved exactly.

## Tokens and CI on sync PRs

- **No `github-token`** (recommended when you have the [Claude GitHub App](https://github.com/apps/claude) installed): the action exchanges the workflow's OIDC token for a short-lived app token (`id-token: write` required). Commits pushed with it **do** trigger your CI on the sync PR.
- **`github-token: ${{ secrets.GITHUB_TOKEN }}`** works, but GitHub suppresses workflow triggers for its pushes — your CI will not run on the sync PR (close/reopen it to trigger manually).
- **A fine-grained PAT or custom app token** with contents + pull-requests + issues write also works and triggers CI.

## Security

This action processes untrusted third-party content (upstream commits), so the write paths are deliberately boring:

- Fast-forwards and all pushes/PR/issue creation are plain shell — the agent's only job is editing files on a sync branch and writing a report. It gets a minimal tool allowlist (git subcommands that can't push, plus your `verify` command) and no GitHub API access.
- Upstream text embedded in prompts is fenced and explicitly marked untrusted; the agent is instructed to never follow instructions found in it.
- Agent-config files that upstream could use for prompt injection (`CLAUDE.md`, `.claude/`, `.mcp.json`, etc.) are forcibly restored to your fork's version after every merge — mechanically, before and after the agent runs, regardless of what the agent does.
- Everything except byte-identical fast-forwards lands through a PR you review.

## Caveats

- GitHub disables cron schedules on public repos after 60 days without repository activity, and only runs them from the default branch.
- A sync PR closed without merging is remembered: that exact upstream state won't be re-proposed, but new upstream commits will trigger a fresh PR. Long-term rejections belong in `ignore`.
- If you push your own commits to a `fork-tender/*` branch, the action leaves that PR alone (and tells you so in a comment) until it's closed or merged.
- The `fork-tender/*` branch namespace and the `fork-tender` / `fork-tender:broken` labels belong to the action.
- Upstream changes to `.github/workflows/` are dropped (protected path) — most tokens can't push workflow changes anyway. Apply those manually when you want them.

## Development

Local git-level tests (no GitHub or LLM access needed — requires `git`, `jq`, `yq`):

```sh
./test/fixture.sh
```

Linting: `pnpm lint` for the repo tooling, plus `shellcheck scripts/*.sh test/*.sh`, `shfmt -d -bn -sr -ci scripts test`, `actionlint`, and `zizmor .` for the action itself.

## Related research

- [Automating Fork Maintenance with AI Agents | Cohere](https://cohere.com/blog/automating-fork-maintenance-with-ai-agents) and [cohere-ai/vllm-skills](https://github.com/cohere-ai/vllm-skills) — the baseline-gate, rerere, and conflict-context techniques are borrowed from their control-loop design.
- [How we automated GitHub Actions runner updates with Claude | Depot](https://depot.dev/blog/how-we-automated-github-actions-runner-updates-with-claude) — the draft-PR-for-review pattern.
- [anthropics/claude-code-action](https://github.com/anthropics/claude-code-action) — powers the agent phase.

<!-- license -->

## License

[MIT](license.txt) © [Eric Mika](https://ericmika.com)

<!-- /license -->
