---
name: Renovate Risk Analysis
description: "Analyzes Renovate PRs and posts risk/impact assessment as PR comment"
on:
  pull_request:
    types: [opened, synchronize]
  bots: ["renovate[bot]"]
  skip-roles: [admin, maintainer, write]

permissions:
  contents: read
  pull-requests: read

engine:
  id: claude
  env:
    ANTHROPIC_BASE_URL: https://api.minimax.io/anthropic
    ANTHROPIC_MODEL: MiniMax-M2.7

secrets:
  ANTHROPIC_AUTH_TOKEN: ${{ secrets.MINIMAX_API_KEY }}

network:
  allowed:
    - defaults
    - api.minimax.io

safe-outputs:
  create-pull-request-review-comment:
    max: 1
    target: "triggering"

timeout-minutes: 15
---

# Renovate PR Risk & Impact Analysis

You are analyzing a Renovate pull request for risk and impact.

## Your Task

1. **Identify the update**: What dependency/package is being updated? What is the version delta?
2. **Check for automerge**: Does this PR have the `automerge` label or will it auto-merge based on the update type?
3. **Changelog analysis**: Read any relevant changelog or release notes if available in the repository.
4. **File impact**: What files are changed? Classify as:
   - Core infrastructure (Cilium, Flux, storage, networking)
   - Shared charts/templates (app-template, external-secrets)
   - Application-specific (individual app HelmReleases)
5. **Risk assessment**: Evaluate:
   - Breaking change potential
   - Security implications
   - Blast radius (how many apps/services affected)
   - Rollout complexity

## Output Format

Post a comment on the PR with this structure:

```
## Risk & Impact Analysis

**Update:** {package} {old_version} → {new_version}
**Automerge:** {Yes/No + reason}
**Files changed:** {count}

### Impact Classification
- Scope: {core-infra | shared-chart | app-specific}
- Affected components: {list}

### Risk Level: 🟢 Low / 🟡 Medium / 🔴 High
{reasoning}

### Notes
{any additional observations, recommendations, or concerns}
```
