# AI Engineering System

A reusable engineering system for planning, building, reviewing, testing and learning with AI agents across software projects. v0.2 turns it into an executable Claude Code plugin.

## Why I built this

I built this after working with AI coding agents day to day and repeatedly running into the same problems.

They were fast, but they had a tendency to over-engineer solutions, introduce abstractions that weren't necessary and make changes that looked reasonable in isolation without fully understanding their effect on the rest of the codebase.

The more frustrating problems were the subtle ones. A change could appear perfectly sensible in a diff but introduce unexpected behaviour elsewhere because the agent hadn't understood an existing data flow, component lifecycle or architectural decision. Those issues often only surfaced when I manually tested the application, sometimes wiping out much of the time the AI was supposed to save.

Good engineering teams reduce these kinds of failures through planning, shared standards, specialist review, testing and accumulated knowledge. I wanted to see what happens when AI agents work with those same disciplines rather than treating every coding task as an isolated prompt.

This repository is my attempt at that: a reusable system for how agents plan, build, review, test and learn across software projects.

## What it does

Instead of asking one agent to understand a request, make every decision, write the code and declare the result finished, the system separates those responsibilities.

It provides:

- engineering standards and guardrails;
- collaborative planning before implementation;
- specialist responsibilities for frontend, backend, platform, security and QA;
- work specifications and architectural decision records;
- deterministic quality gates and approval guardrails;
- independent review from a different provider;
- project-level knowledge and regression tracking;
- and a learning process for turning failures and discoveries into durable knowledge.

The goal isn't to make agents generate more code. It's to make AI-assisted engineering more deliberate, verifiable and cumulative.

## Core principles

### Agents have autonomy over implementation, not authority over intent

Once requirements and architecture are agreed, implementation agents should be able to work without asking about every small coding decision. They shouldn't silently redefine the product, architecture, security model or other important human decisions.

### Planning comes before implementation

Planning is a collaborative engineering activity, not just prompt preparation. Requirements, assumptions, architecture, risks and acceptance criteria should be understood before implementation begins.

### Challenge assumptions

A proposed solution is input to the discussion, not automatically the correct implementation. When realistic alternatives exist, the system should explain the trade-offs and recommend an approach rather than simply agreeing.

### Local correctness isn't enough

Code can look perfectly reasonable in isolation and still be wrong within the wider system. Agents need enough project context to consider existing architecture, data flows, state, side effects, security boundaries and established behaviour before changing them.

### Prefer evidence over confidence

Tests, builds, linters, security tools and performance measurements are stronger evidence than an agent saying something looks correct. If a required check hasn't run, the system doesn't claim it passed.

### Independent review matters

The model that implemented a change isn't independent evidence that the change is correct. Work is only marked ready for final human acceptance after an independent review from a genuinely different provider; Claude reviewing Claude doesn't count.

### Prefer the simplest solution that meets the requirements

Avoid speculative abstractions, unnecessary dependencies, unrelated refactors and architecture designed for hypothetical future problems. Simplicity matters, but not at the expense of security, correctness or reliability.

### Humans retain high-impact authority

Agents can have substantial autonomy without having unlimited authority. Architectural uncertainty, destructive operations, releases, merges and other consequential actions return to a human.

## How it works

A typical piece of work moves through this lifecycle:

```text
Conversation and planning
    ↓
Approved work specification
    ↓
Delivery by specialist agents
    ↓
Deterministic quality gates
    ↓
Security / QA
    ↓
Independent review
    ↓
Human acceptance
    ↓
Learning
```

The exact path depends on the type and risk of the change, but the principle stays the same: **understand the work, implement it, prove it and preserve what was learned.**

### Responsibilities in Claude Code

Planning is the main conversational interface: it runs in your interactive Claude Code session, not in a background agent. Implementation and review responsibilities use Claude Code's native subagents and skills.

| Responsibility | What it does | Claude Code mechanism |
| :- | :- | :- |
| Planning | Clarifies requirements, challenges assumptions, explores architecture and produces an agreed work specification | Main session with `/ai-engineering:plan` |
| Orchestration | Coordinates approved work, dependencies, specialists and gates | Main session with `/ai-engineering:deliver` |
| Frontend | UI architecture, accessibility, browser behaviour, performance and design fidelity | `frontend` agent |
| Backend | APIs, data, authentication, authorisation, concurrency, reliability and scalability | `backend` agent |
| Platform | Implements approved infrastructure as code up to a reviewed plan; design stays in the main session | `platform` agent |
| Security | Adversarial review of assumptions and boundaries | `security-reviewer` agent |
| QA | Validates acceptance criteria against real test evidence | `qa` agent |
| Learning | Turns discoveries, failures and regressions into durable project knowledge | `learning` agent with `/ai-engineering:learn` |
| Independent review | A separate challenge from a different provider | `/ai-engineering:review` plus a configurable external command |

The agent definitions live in [`plugins/ai-engineering/agents/`](plugins/ai-engineering/agents/) and the skills in [`plugins/ai-engineering/skills/`](plugins/ai-engineering/skills/). The security and QA agents have no file-editing tools, but Claude Code can't make a Bash-enabled agent strictly read-only; [the architecture document](docs/architecture.md#reviewer-isolation) explains the limits.

### Deterministic enforcement

Important checks are enforced by plugin hooks rather than left to instructions:

- the core engineering standards are added to every main session at start-up;
- high-impact commands require explicit human approval;
- the learning agent can only write inside `.agents/`.

Each implementation agent's work is checked by the project's fast quality gate when it finishes, with a bounded number of fix rounds before escalation. The delivery workflow runs the gate through Claude Code's Bash tool, so your permission rules and sandbox still apply, and a script reports the verdict.

Implementation checks read gate commands from the committed project configuration, falling back to the uncommitted file, with a warning, only while none is committed. During review, the full gate and the external reviewer come from the base branch, so a change can't define the checks that certify it.

**The plugin is not an isolation boundary.** Running a gate, test or build executes the project's code with your privileges, so a harmless-looking `npm test` runs whatever an untrusted change contains. Run untrusted code only in an isolated environment with scoped or no credentials and appropriate network controls. [The architecture document](docs/architecture.md#trust-boundary-for-project-code) sets out the trust boundary.

### Human approval

Infrastructure apply/destroy, cloud and Kubernetes deletions, SQL `DROP`/`TRUNCATE`, force pushes, pushes to `main`/`master`, PR merges, releases, package publishing and deploy/release tasks require explicit human approval in every environment. In an interactive session, including auto mode, Claude Code shows a permission prompt; where no human can answer, the operation is denied. Behaviour under `bypassPermissions` hasn't been verified.

**Hooks are guardrails, not a security sandbox.** They see only the command text Claude submits and can be evaded by indirection. Use real sandboxing, least-privilege credentials, protected branches and CI/CD approvals for hard boundaries.

### Independent review

The system stays provider-neutral: a project configures any command as `externalReview` in `.agents/gates.json` ([contract](docs/external-review.md)). When none is configured, review reports `EXTERNAL REVIEW: NOT CONFIGURED` and the work isn't marked ready for final acceptance. That doesn't block implementation, local testing, commits or draft pull requests.

## Engineering standards

When priorities conflict, the default order is:

1. Security
2. Correctness
3. Reliability
4. Scalability
5. Accessibility
6. Maintainability and readability
7. Performance
8. SEO
9. Simplicity

These aren't an excuse for unnecessary complexity. The preferred implementation is still the simplest one that satisfies the higher-priority requirements.

Each rule has one authoritative home in the plugin's standards skills: [engineering](plugins/ai-engineering/skills/engineering-standards/SKILL.md), [security](plugins/ai-engineering/skills/security-standards/SKILL.md), [frontend](plugins/ai-engineering/skills/frontend-standards/SKILL.md) and [platform](plugins/ai-engineering/skills/platform-standards/SKILL.md). Process guidance for each type of change lives in the [playbooks](plugins/ai-engineering/skills/playbooks/SKILL.md).

## Project knowledge

The global system describes **how software should be engineered**. Each application separately records **what that particular system is and why it works the way it does**, under `.agents/`:

```text
.agents/
├── gates.json          # fast, full and externalReview commands
├── project/            # system overview, architecture, domains, data, design
├── decisions/          # ADRs
├── specs/
│   ├── active/         # planning sessions and work specifications
│   └── archive/
├── learnings/
├── failures/
└── regressions/
```

This gives agents relevant project context without forcing every future session to reconstruct the application from conversation history. The project's `AGENTS.md` holds project-specific facts only; the global standards come from the plugin and are never copied into it.

**Repository files are durable memory. Conversation history is temporary working context.** Claude Code's automatic memory is a personal convenience, not a replacement for this reviewed, version-controlled knowledge.

## Work specifications and decisions

Each meaningful feature, bug fix, migration, refactor or architectural change has its own work specification, capturing the objective, requirements, decisions, risks, tests and acceptance criteria. Long-lived architectural decisions belong in ADRs rather than disappearing into a chat transcript. Templates live with the skills that use them: [planning](plugins/ai-engineering/skills/plan/templates/) and [learning](plugins/ai-engineering/skills/learn/templates/).

## Learning from mistakes

One of the main goals of the system is to avoid paying repeatedly for the same mistake. Implementation failures, incidents, security findings, regressions, review findings and human corrections can become project knowledge, an ADR, a regression record or a proposed engineering guardrail.

They don't automatically rewrite the rules. Permanent guardrails are deliberate, reviewed decisions, made through a pull request to this repository ([process](CONTRIBUTING.md)).

## Context and token efficiency

More context isn't automatically better. The system aims to use the minimum reasoning and context necessary to complete work reliably, through progressive disclosure, relevant project knowledge rather than entire histories, deterministic tools for deterministic questions, concise work specifications, explicit task state, bounded retries, parallel work where it's genuinely independent, and compressed durable learnings.

In v0.2 this is built in: only the core standards and short skill and agent descriptions are always loaded; domain standards, playbooks and templates load on demand; lifecycle skills cost nothing until invoked; and agents receive the work specification and their task rather than the conversation history. A repository check enforces a budget on always-loaded context.

The objective isn't the lowest token usage at any cost. It's the **lowest practical cost per successfully completed engineering task at the required quality**.

## Model routing

Models are selected according to task complexity and risk rather than permanently tied to job titles:

```text
Planning / complex architecture / security
    → high-reasoning model (Opus)

Routine implementation / orchestration / QA / learning
    → capable execution model (Sonnet)

Lint / format / typecheck / tests / builds / security scans
    → deterministic tools

Pull-request review
    → independent provider
```

Each agent's `model` field is the single source of routing configuration. Model aliases are used rather than pinned model IDs, so routing follows model improvements without hard-coding today's names. See the [model policy](docs/model-policy.md).

## Getting started

### Prerequisites

- [Claude Code](https://code.claude.com/docs) (v0.2 was developed and tested with v2.1.289)
- `git`, `bash` and [`jq`](https://jqlang.org/) on the `PATH`; the hooks are bash scripts
- The project you apply it to should be a git repository

### Install

Installation has two steps, done once rather than every session.

1. **Register the marketplace.** This repository is a Claude Code marketplace named `ai-engineering-system`. Registering it records where to fetch the plugin from, pinned to a release tag. It doesn't enable anything yet.
2. **Install the plugin.** This fetches the `ai-engineering` plugin from that marketplace and enables it.

```text
claude plugin marketplace add asholiver/ai-engineering-system@v0.2.0
claude plugin install ai-engineering@ai-engineering-system
```

The example pins `v0.2.0`. Releases are tagged `v<version>` and listed in the [changelog](versions/CHANGELOG.md), so substitute the release you want.

The marketplace registration applies to every project on your machine. The plugin's install scope decides where it is enabled:

- `--scope user` (the default): enabled in every project you open. Its session-start standards and command guards then apply everywhere, not only in projects you've set up.
- `--scope local`: enabled only in the project you run the command from, and only for you.

Either way it persists across sessions until you uninstall or disable it. Install changes take effect in a new session or after `/reload-plugins`. Auto-update is off for this marketplace, so you stay on the pinned release until you upgrade deliberately; see [Updating](docs/consuming-project.md#updating).

Opening this repository's source doesn't load the plugin. The `/ai-engineering:*` commands are available only in sessions where the plugin is installed and enabled, or loaded with `--plugin-dir`.

### Set up each project

In each project that should use the system, run this once:

```text
/ai-engineering:setup
```

It never overwrites existing files without showing you the change first, and it creates:

- the `.agents/` knowledge layout shown above;
- `.agents/gates.json`, after confirming your `fast` and `full` gate commands with you (`externalReview` stays empty until you configure one);
- a project-specific `AGENTS.md`, and a `CLAUDE.md` that imports it so it keeps loading;
- `.claude/settings.json` entries that enable the plugin for everyone who clones the project once they trust the folder, and register the marketplace pinned to the installed plugin's release tag, with auto-update off, on machines that don't already have a marketplace named `ai-engineering-system`. A machine that already has one keeps its existing registration, which may point at a different release; check with `/plugin`;
- optionally, the worktree setting needed for parallel delivery.

Review and commit what it creates. Until `.agents/gates.json` is committed, implementation checks use the uncommitted file with a warning, and review reads the full gate and the external review command only from the base branch.

After setup, nothing else needs installing: open the project in Claude Code and use the `/ai-engineering:*` commands below.

### Start a piece of work

```text
/ai-engineering:plan WORK-001      discuss, decide, then write the work specification and ADRs
/ai-engineering:deliver WORK-001   implement the approved specification through specialist agents
/ai-engineering:review WORK-001    full gate, security and QA checks, independent review
/ai-engineering:learn              record a learning, regression or incident
```

Planning ends with a work specification you explicitly approve. Delivery stops at any decision the specification doesn't make. Review reports whether the work is ready for your final acceptance.

Multiple unrelated work streams can run in the same repository, each with its own specification and state. Parallel implementation uses git worktree isolation once the project opts in.

### Develop or test unreleased changes

To try source that hasn't been released, load the plugin from a local checkout for a single session:

```text
cd /path/to/a-test-project
claude --plugin-dir /path/to/ai-engineering-system/plugins/ai-engineering
```

For that session the local copy replaces any installed `ai-engineering` plugin, unless managed settings list `ai-engineering` under `enabledPlugins`. In that case the local copy isn't loaded, the installed release keeps running, and Claude Code reports `--plugin-dir copy of "ai-engineering" ignored: plugin is locked by managed settings`. Nothing is installed or recorded, so the next session without the flag goes back to the installed release.

### Developing this repository

Work on the system itself is governed by an installed, released version, not by the source being edited:

1. Install a released version (`--scope local` in this repository is enough).
2. Develop the next version in this repository with that release active, so the workflow guiding the work doesn't change halfway through it.
3. Test the changed plugin in a separate session with `--plugin-dir`, ideally against a test project.
4. Release it by following [CONTRIBUTING.md](CONTRIBUTING.md), then upgrade the installed version.

## Status

**v0.1** established the reference architecture: principles, responsibilities, guardrails, workflows, knowledge model and model-routing approach.

**v0.2** implements the Claude Code integration as a plugin, released as `v0.2.0`. Each release is tagged `v<version>`; the [changelog](versions/CHANGELOG.md) records what it contains, and known limitations and open items are listed in the [architecture document](docs/architecture.md).

## Repository structure

```text
ai-engineering-system/
├── .claude-plugin/marketplace.json   # marketplace listing the plugin
├── plugins/ai-engineering/           # the plugin: agents, skills, hooks, scripts
├── docs/                             # architecture, policies, contracts, ADRs
├── tests/run.sh                      # automated tests for the hook scripts
├── scripts/check.sh                  # this repository's quality gate
├── AGENTS.md                         # instructions for working on this repository
├── CONTRIBUTING.md
└── versions/CHANGELOG.md
```

## Documentation

- [Architecture](docs/architecture.md): components, enforcement, trust boundaries, limitations
- [ADR-0001](docs/decisions/ADR-0001-claude-native-architecture.md): why v0.2 uses Claude Code's native mechanisms
- [ADR-0002](docs/decisions/ADR-0002-gate-execution-trust-boundary.md): how gates execute project code, and the trust boundary
- [External review contract](docs/external-review.md)
- [Consuming project structure and updates](docs/consuming-project.md)
- [Model policy](docs/model-policy.md)
- [Contributing](CONTRIBUTING.md): rule promotion, releases, documentation style

## Philosophy

AI makes writing code faster. That doesn't remove the need for engineering discipline; it makes that discipline more important.

The aim of this project is to give agents enough autonomy to be genuinely useful while surrounding that autonomy with planning, context, verification, independent challenge and human judgement.

A good result isn't simply that the agent produced working code quickly. It's that the right thing was built, the implementation fits the wider system, important claims were verified, unintended consequences were considered and useful knowledge survives for the next piece of work.

## About

Built by **[Ashley Oliver](https://www.linkedin.com/in/ashleyioliver/), Senior Product Engineer**.

I build software products and explore how AI-assisted engineering can become more reliable, maintainable and effective in real-world development.
