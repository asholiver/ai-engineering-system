# Changelog

## 0.2.0
Claude Code native architecture (ADR-0001).
- Repository is now a Claude Code marketplace publishing the `ai-engineering` plugin.
- Specialist roles are native subagents: frontend, backend, platform (implementation), security-reviewer, qa, learning, with model routing in agent frontmatter.
- Planning and orchestration run in the main session through the `plan` and `deliver` skills; `review`, `learn` and `setup` skills added.
- Rules merged into four standards skills with one authoritative copy of each rule; core standards injected at session start and preloaded into agents.
- `workflows/` renamed to playbooks and packaged as the `playbooks` skill.
- Hooks: intent-based human-approval guard for high-impact commands, learning-agent write guard, and an opt-in (`AI_ENGINEERING_HOOK_GATES=1`) bounded fast gate for implementation agents.
- Provider-neutral external review contract (`externalReview` in `.agents/gates.json`); not configured means not ready for final acceptance.
- Removed `models/routing.yaml` and `tooling/` (superseded); README completed (previously truncated).
- Gate commands are read from committed `.agents/gates.json`; the external reviewer is read from the base ref; high-impact configured commands are refused.
- Gate execution trust boundary (ADR-0002), from an independent security review: gates run through the Bash tool by default so the user's permissions and sandbox apply, and the hook no longer executes project code unless opted in; `/ai-engineering:review` reads the full gate from the base ref and reports changes to it. The plugin is documented as not being an isolation boundary.
- `/setup` pins the marketplace to the plugin's release tag with auto-update off; parallel worktree delivery requires `worktree.baseRef: "head"`.
- Added table-driven hook tests and `scripts/check.sh` (including version consistency).

## 0.1.0
Initial reusable AI engineering operating system covering planning, concurrent work sessions, orchestration, specialist agents, independent review, security/scalability/accessibility/performance/SEO/code-quality rules, infrastructure workflows, testing/regression, project knowledge, model routing, token efficiency, deterministic gates, and human decision boundaries.
