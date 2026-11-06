# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-11-01

### Maintenance

- Update the bundled `anthropics/claude-code-action` from v1.0.264 to v1.0.266, bringing Claude Code to 2.1.316.

## [1.1.0] - 2026-10-29

### Added

- Add an `effort` input supporting `low`, `medium`, `high`, and `xhigh`, defaulting to `high`.

### Changed

- Change the default Claude model from `claude-opus-5` to `claude-opus-5-5`.
- Increase the default agent turn budget from 100 to 200.
- Instruct the merge agent to regenerate lockfiles after resolving manifest conflicts, or report a stale lockfile with a `partial` outcome when regeneration is unavailable.
- Tell the merge agent its granted tools and require permission denials to be reported separately from missing tools or network failures, including exact commands requiring maintainer action.

### Fixed

- Instruct the merge agent to bypass Git hooks for sync merges and commits so hooks installed during verification do not block sync work.

### Documentation

- Document runner toolchain setup and narrowly scoped permissions for regenerating lockfiles.
- Add a GitHub release-version badge to the README.

### Maintenance

- Update the bundled `anthropics/claude-code-action` from v1.0.243 to v1.0.264.
- Update shared-config to ^8.14.0 and pnpm to 12.16.1, clean up installation settings, and align contributor Node.js support with `^24.16.0 || >=26.3.0`.
- Replace the installation-time `skills` CLI hook with pnpm-managed skill installation into `.agents/skills` and `.claude/skills`.
- Refresh CI and release actions, including migration to `github-action-release` v3, and move automated dependency-update PRs to a monthly schedule.
- Adjust link-check CI to ignore loopback URLs and accept empty URL lists.

## [1.0.2] - 2026-10-07

### Documentation

- Add a comparison of related fork-sync and conflict-resolution projects.

### Maintenance

- Update the bundled `anthropics/claude-code-action` from v1.0.193 to v1.0.243.
- Refresh development dependencies, upgrade contributor tooling to pnpm 12.9.1, and adjust ESLint peer-dependency compatibility settings.
- Add installation-time development-skill synchronization and rename the `clean` script to `clean-deep`.
- Add weekly and manually triggered automation for dependency-update pull requests.
- Pin first-party workflow actions to commit SHAs and require hash pins in workflow audits.
- Improve website link checks with HTML sitemap discovery, Lychee configuration checkout, and pinned discovery tools.

## [1.0.1] - 2026-08-17

### Fixed

- Mint a fresh Claude GitHub App token for publication instead of reusing the revoked agent token, with a warned fallback to the workflow token and token revocation afterward.
- Record failed commits, pushes, and PR operations as `error` outcomes, continue processing other upstreams, and fail the run instead of reporting publication success.
- Avoid checking out an already-current sync branch with unresolved conflicts so abandoned merges can be finalized for broken draft PRs.
- Prevent truncated commit logs and conflict-file lists from aborting runs because of SIGPIPE under `pipefail`.

### Documentation

- Explain that Actions must be enabled on forks and add a 1Password CLI example for configuring the Claude OAuth repository secret.

### Maintenance

- Add regression coverage for failed pushes, error outcomes, workflow summaries, and returning to the base branch after publication failure.

## [1.0.0] - 2026-08-17

### Added

- Introduce a composite GitHub Action that detects changes from a fork's GitHub parent or multiple configured upstreams, including custom branches and Git URLs.
- Fast-forward forks without unique commits through GitHub's Sync Fork API without invoking Claude, with an optional notification-issue mode.
- Merge diverged upstreams on dedicated sync branches using cached `rerere` resolutions and Claude evaluation and conflict resolution, preserving fork intent without rewriting released history.
- Support ignored upstream commits, repository-specific agent guidance, and configurable protected paths that retain fork-owned agent configuration and workflows.
- Run configurable verification with a pre-sync baseline to distinguish existing failures from sync regressions, with a default 30-minute timeout configurable through `FT_VERIFY_TIMEOUT`.
- Create or refresh sync PRs with evaluation and verification reports, publish uncertain or broken results as drafts, and record skip recommendations in PR comments or issues.
- Remember declined upstream states and leave sync PR branches containing human commits untouched.
- Accept Anthropic API keys or Claude OAuth tokens through inputs or environment variables, preferring OAuth when both are present, with an optional GitHub token override.
- Provide configurable Claude models, turn budgets, bot allowances, and extra tool permissions, plus a dry-run mode that attempts local merges without invoking Claude or publishing.
- Expose per-upstream JSON outcomes and created or updated PR URLs as action outputs, alongside a workflow summary.

### Documentation

- Add workflow installation and authentication guides, configuration examples, output references, sync and security caveats, and development instructions; mark the action under development until 2.0.

### Maintenance

- Set up pnpm-based linting, local Git fixture tests, cross-platform CI, workflow audits, link checks, and tagged releases with automatic major-version tag updates.

[1.0.0]: https://github.com/kitschpatrol/github-action-fork-tender/releases/tag/v1.0.0
[1.0.1]: https://github.com/kitschpatrol/github-action-fork-tender/compare/v1.0.0...v1.0.1
[1.0.2]: https://github.com/kitschpatrol/github-action-fork-tender/compare/v1.0.1...v1.0.2
[1.1.0]: https://github.com/kitschpatrol/github-action-fork-tender/compare/v1.0.2...v1.1.0
[1.1.1]: https://github.com/kitschpatrol/github-action-fork-tender/compare/v1.1.0...v1.1.1
