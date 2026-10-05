# ADR-0001: Claude Code native architecture for v0.2
## Status
Accepted. Gate execution amended by [ADR-0002](ADR-0002-gate-execution-trust-boundary.md).
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
- The automatic fast gate runs from a hook, outside Claude Code's permission checks and sandbox. The full gate and external review are run by the main session through the Bash tool: permission checks and any sandbox apply to that call, but no permission rule inspects the configured command itself, and it runs in the change's checkout with the user's privileges and credentials, without isolation. Configured commands are read from committed config (gates at `HEAD`, external review at the base ref) and refused when high-impact.
  - *Correction:* this item originally said all configured gate and review commands ran outside Claude Code's permission checks and sandbox. That was only true of the hook-run fast gate.
  - *Qualified by [ADR-0002](ADR-0002-gate-execution-trust-boundary.md):* gates now run through the Bash tool by default, and the hook runs them only with `AI_ENGINEERING_HOOK_GATES=1`. Implementation checks fall back to an uncommitted `.agents/gates.json`, with a warning, while none is committed at `HEAD`. Review reads the full gate only from the base ref. Running any gate executes project code with the user's privileges.
- QA and security-reviewer cannot be made strictly read-only while keeping Bash; the limitation is documented and a tamper-evidence hook is proposed.
- Projects pin the marketplace to a release tag with auto-update off; marketplace refs cannot be commit SHAs, so this is reproducible but not tamper-proof.
- Open decisions: the external review provider and integration; whether to add executable workflows; pinned model IDs versus aliases once evaluation data exists.
