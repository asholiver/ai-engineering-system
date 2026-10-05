# AI Engineering System (repository instructions)

This repository is the ai-engineering system itself: a Claude Code marketplace (`.claude-plugin/marketplace.json`) publishing one plugin (`plugins/ai-engineering/`). Read `docs/architecture.md` before structural changes.

The engineering standards below apply to work on this repository too:

@plugins/ai-engineering/skills/engineering-standards/SKILL.md

## Working on this repository
- Each global rule has exactly one authoritative home in `plugins/ai-engineering/skills/*-standards/`. Do not restate rules in docs, agents or templates; link to them.
- Model routing lives only in agent frontmatter.
- Keep always-loaded text small: the core standards, agent descriptions and model-invocable skill descriptions are paid for in every session. `scripts/check.sh` enforces budgets.
- Hook scripts are bash + jq. Every behaviour change needs a case in `tests/run.sh`.
- Changes to global standards follow `CONTRIBUTING.md`; they are never made automatically from a project learning.
- Run `scripts/check.sh` before declaring work done, and update `versions/CHANGELOG.md` and the plugin version for releases.
