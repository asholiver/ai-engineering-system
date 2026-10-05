# ADR-0001: Claude Code native architecture for v0.2
## Status
Accepted
## Context
v0.1 was advisory prose: role descriptions, rules, workflows and a model routing file that nothing executed or enforced. Only the root `AGENTS.md` was loaded by Claude Code. Claude Code now provides plugins, marketplaces, subagents, skills, hooks, permissions, per-agent model selection, worktree isolation and executable workflows.
## Decision
- Ship v0.2 as the `ai-engineering` plugin in this repository's marketplace, plus a `/setup` skill. No separate bootstrap CLI and no Node tooling.
- The main interactive session is Planning/Spec and orchestration (`plan`, `deliver` skills). Frontend, Backend, Platform implementation, Security, QA and Learning are native subagents.
- Global standards live once, in plugin skills. Main sessions receive core standards through a SessionStart hook; subagents preload them. Consuming projects' `AGENTS.md` holds project facts only.
- Deterministic enforcement uses plugin hooks: intent-based human-approval guard, learning-agent write guard and an automatic bounded fast gate.
- Agent frontmatter `model` is the only model routing source; `models/routing.yaml` is removed. v0.2 uses aliases.
- Independent review stays provider-neutral through the `externalReview` command contract. Not configured means not ready for final acceptance, without blocking other work.
- `.agents/` remains the reviewed, version-controlled project knowledge store; automatic memory does not replace it.
- `workflows/` is renamed to playbooks to avoid confusion with executable Claude Code workflows.
## Why
Native mechanisms are maintained by the platform, load progressively (lower context cost) and can be enforced deterministically. Prose alone cannot guarantee "never claim a check passed" or human approval for destructive operations.
## Alternatives considered
### Copy global rules into each project's AGENTS.md
Rejected: copies drift and create multiple authoritative versions.
### Enforce approval with permissions.deny rules
Rejected for distribution: plugins cannot ship permission rules, and plain string rules are easier to bypass than intent classification. Projects may still add their own.
### Agent Teams for parallel implementation
Rejected for v0.2: experimental, not resumable, one team per session.
### Claude reviewing Claude as the independent review
Rejected: correlated reasoning failures; the requirement is a genuinely different provider.
## Consequences
- Plugin agents ignore `hooks`, `permissionMode` and `mcpServers` frontmatter; enforcement must stay plugin-level.
- Hooks are guardrails, not a sandbox; hard boundaries need OS sandboxing, least-privilege credentials and CI/CD protections.
- Hook `ask` is treated as deny where no human can answer (`claude -p`); behaviour under `bypassPermissions` is unverified.
- Teammates must trust the project folder before the project-declared marketplace applies.
- Configured gate and review commands run outside Claude Code's permission checks and sandbox; they are read from committed config (gates at `HEAD`, external review at the base ref) and refused when high-impact.
- QA and security-reviewer cannot be made strictly read-only while keeping Bash; the limitation is documented and a tamper-evidence hook is proposed.
- Projects pin the marketplace to a release tag with auto-update off; marketplace refs cannot be commit SHAs, so this is reproducible but not tamper-proof.
- Open decisions: the external review provider and integration; whether to add executable workflows; pinned model IDs versus aliases once evaluation data exists.
