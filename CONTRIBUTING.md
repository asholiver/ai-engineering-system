# Contributing

Shared guardrails are engineering infrastructure.

Before changing them:
- identify the problem
- keep guidance concise and actionable
- avoid project-specific rules in global rules
- avoid duplication: each rule has one authoritative home in `plugins/ai-engineering/skills/*-standards/`
- consider token/context cost (always-loaded text is budgeted by `scripts/check.sh`)
- update the changelog
- prefer machine-verifiable improvements (a hook or check over prose)

## Promoting a project learning to a global rule
Project learnings never change shared guardrails automatically.
1. The learning is recorded in the project's `.agents/learnings/` with `Scope: General (proposed guardrail)`.
2. A human opens a pull request to this repository with the proposed rule, the evidence (incidents, findings, repeated mistakes) and the standards file it belongs in.
3. The change is reviewed by a human before merge. Prefer merging into an existing rule over adding a new one.

## Releasing
A release is a human action.
1. Bump `version` in `plugins/ai-engineering/.claude-plugin/plugin.json` (consumers keep their cached copy until it changes) and add the matching `versions/CHANGELOG.md` entry; `scripts/check.sh` verifies they agree.
2. Merge to `main` after review.
3. Create the tag `v<version>` on that commit and never move it; consuming projects pin to it.

## Checks
Run `scripts/check.sh`. It validates the plugin and marketplace, runs the hook tests and enforces context budgets.
