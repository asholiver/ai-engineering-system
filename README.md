# AI Engineering System

A reusable, self-improving operating system for AI-assisted software engineering, delivered as a Claude Code plugin.

It defines how agents plan, implement, review, test, secure, deploy and learn from engineering work, while project-specific knowledge stays inside each application repository. The goal is not simply to make AI agents write more code; it is to make them behave like a coordinated engineering team that becomes more effective over time.

Agents have **autonomy over implementation, not authority over intent**.

## Goals

- high engineering quality by default
- security and correctness before convenience
- scalable architecture rather than happy-path implementations
- semantic, accessible and performant frontend development
- simple, human-readable code and feature/domain-oriented architecture
- meaningful automated testing and independent review
- explicit architectural decisions
- safe infrastructure and deployment practices
- efficient use of models, context and tokens
- durable learning from mistakes and discoveries
- support for multiple concurrent work streams

## Engineering lifecycle

```text
Discuss → Decide → Specify → Implement → Prove → Independent Review → Human Acceptance → Deploy → Observe → Learn
```

Not every change needs every stage, but stages are skipped only deliberately.

## How it maps onto Claude Code

| Capability | Claude Code mechanism |
| :- | :- |
| Planning / Spec | The main interactive session, following `/ai-engineering:plan` |
| Orchestration | The main session, following `/ai-engineering:deliver` |
| Frontend, Backend, Platform (implementation) | Subagents `ai-engineering:frontend`, `:backend`, `:platform` |
| Security | Subagent `ai-engineering:security-reviewer` (no file-editing tools) |
| QA | Subagent `ai-engineering:qa` (no file-editing tools) |
| Learning | Subagent `ai-engineering:learning`, restricted to writing `.agents/` |
| Independent review | `/ai-engineering:review` plus a provider-neutral external review command |
| Global engineering standards | Skills; core standards injected at session start and preloaded into agents |
| Playbooks | The `playbooks` skill, loaded on demand |
| Deterministic enforcement | Plugin hooks: approval guard, write guard, automatic fast gate |

See [docs/architecture.md](docs/architecture.md) for the full design and its limits.

## Install

This repository is a Claude Code marketplace containing one plugin, `ai-engineering`.

```text
/plugin marketplace add asholiver/ai-engineering-system
/plugin install ai-engineering@ai-engineering-system
```

Then, in an application repository, run `/ai-engineering:setup`. It creates the `.agents/` knowledge layout, `.agents/gates.json`, a project-specific `AGENTS.md`, a `CLAUDE.md` that imports it, and project settings that register the marketplace at a pinned release tag with auto-update off and enable the plugin for teammates once they trust the folder. Updates are deliberate: see [docs/consuming-project.md](docs/consuming-project.md#updating).

To try the plugin from a local checkout without installing it:

```text
claude --plugin-dir /path/to/ai-engineering-system/plugins/ai-engineering
```

## Using it

```text
/ai-engineering:plan WORK-001     discuss, decide, write the work spec and ADRs
/ai-engineering:deliver WORK-001  implement an approved spec through specialist agents
/ai-engineering:review WORK-001   full gate, internal checks, external independent review
/ai-engineering:learn             record a learning, regression or incident
```

## Independent review

Implementation receives an independent review from a genuinely different provider before final human acceptance. The system stays provider-neutral: a project configures any command as `externalReview` in `.agents/gates.json` (see [docs/external-review.md](docs/external-review.md)). When none is configured, review reports `EXTERNAL REVIEW: NOT CONFIGURED` and the work is not marked ready for final acceptance. Claude reviewing Claude never substitutes for it. Missing external review does not block implementation, local testing, commits or draft PRs.

## Human approval

High-impact operations (infrastructure apply/destroy, cloud and Kubernetes deletions, SQL DROP/TRUNCATE, force pushes, pushes to main/master, PR merges, releases, package publishing and deploy/release tasks) require explicit human approval in every environment. A plugin hook classifies commands by intent and asks the human before they run. In a real interactive auto-mode session the prompt appeared and declining it prevented execution; in non-interactive runs the operation is denied. Behaviour under `bypassPermissions` is not verified. **Hooks are guardrails, not a security sandbox**: they see only the command text and can be evaded by indirection. Use real sandboxing and least-privilege credentials for hard boundaries.

## Concurrent work

Multiple unrelated work streams (for example `WORK-001 SSO + MFA`, `WORK-002 Billing redesign`) can run in the same repository. Each keeps its own planning session, decisions, acceptance criteria, implementation state and review state under `.agents/specs/active/`. Parallel implementation uses Git worktree isolation; planning flags work streams that start touching shared architectural areas.

## Project knowledge

The engineering system holds reusable engineering behaviour. Application-specific knowledge stays in the application repository under `.agents/` (see [docs/consuming-project.md](docs/consuming-project.md)):

```text
Engineering System   → How should we engineer software?
Project Context      → How does this application work?
Work Specification   → What are we changing now?
ADR                  → Why did we make this architectural decision?
Learning             → What did we discover?
Regression           → What must never break again?
```

`.agents/` is the reviewed, version-controlled source of truth. Claude's automatic memory is a personal convenience and never replaces it.

## Model routing

Models are not permanently tied to job titles. They are selected by task complexity, ambiguity, risk and expected cost per successful task, not by agent seniority. The starting configuration is:

```text
Complex planning / architecture / security   → high-reasoning model (Opus)
Routine implementation / QA / orchestration  → execution model (Sonnet)
Lint / format / tests / build / scanning     → deterministic tooling
PR review                                    → independent external provider
```

The `model` field in each agent's frontmatter is the single authoritative routing configuration. `scripts/check.sh` prints the current routing. Principles and evaluation guidance: [docs/model-policy.md](docs/model-policy.md).

The objective is not minimum token usage at any cost. It is **minimum cost per successfully completed engineering task**.

## Context and token efficiency

The system follows progressive disclosure: agents load only the information the current task needs. Stable engineering instructions, project architecture, current work state and execution evidence stay separate.

In v0.2 this is built in rather than only advised: only the core standards and short skill and agent descriptions are always loaded; domain standards, playbooks and templates load on demand; lifecycle skills cost nothing until invoked; subagents receive the spec path and task rather than the conversation history. `scripts/check.sh` enforces a budget on always-loaded text.

Prefer concise specifications, targeted retrieval, cached stable context, deterministic tools, summarised logs, bounded retries, escalation when necessary, parallel execution of independent work, and compressed durable learning.

Repository files are durable memory. Conversation history is temporary working context.

## Learning

Lessons from failures, incidents, reviews and feedback are recorded in the project's `.agents/` through `/ai-engineering:learn`. Not every observation becomes a rule. A lesson that looks general is recorded as a proposed guardrail; it reaches the shared standards only through a reviewed pull request to this repository (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Repository layout

```text
.claude-plugin/marketplace.json   marketplace listing the plugin
plugins/ai-engineering/           the plugin: agents, skills, hooks, scripts
docs/                             architecture, policies, contracts, ADRs
tests/run.sh                      table-driven tests for the hook scripts
scripts/check.sh                  this repository's quality gate
versions/CHANGELOG.md             release notes
```

## Status

Current version: **v0.2.0**.

v0.1 established the engineering model, agent responsibilities, guardrails, workflows, knowledge model and model-routing strategy. v0.2 is the first provider integration: it connects those concepts to Claude Code through a plugin with project instructions, subagents, skills, hooks, permission prompts, worktrees, per-agent model routing, concurrent work sessions and automated quality gates. See [versions/CHANGELOG.md](versions/CHANGELOG.md).

Open items include the choice of external independent-review provider, a tamper-evidence check for reviewer agents, and executable workflows where they prove their value. [docs/architecture.md](docs/architecture.md) lists the current limitations.

## Philosophy

AI should not replace engineering discipline. It should make engineering discipline easier to apply consistently.

The system therefore favours evidence over confidence, simplicity over unnecessary abstraction, explicit decisions over hidden assumptions, and durable learning over repeatedly solving the same problem.
