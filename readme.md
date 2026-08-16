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

## Usage

```yaml
on:
  workflow_dispatch: {}
  schedule:
    - cron: '0 0 * * 1'

permissions:
  contents: read

jobs:
  tend-forks:
    runs-on: ubuntu-latest
    steps:
      - uses: kitschpatrol/github-action-fork-tender@v1
```

## Requirements

Anthropic API key or OATH token.

## Related research

- [Automating Fork Maintenance with AI Agents \| Cohere](https://cohere.com/blog/automating-fork-maintenance-with-ai-agents)
- [cohere-ai/vllm-skills](https://github.com/cohere-ai/vllm-skills)
- https://github.com/marketplace/actions/rebase-upstream
- https://github.com/anthropics/claude-code-action/blob/main/docs/solutions.md

<!-- license -->

## License

[MIT](license.txt) © [Eric Mika](https://ericmika.com)

<!-- /license -->
