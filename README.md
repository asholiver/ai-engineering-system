# AI Engineering System

A reusable engineering system for planning, building, reviewing, testing and learning with AI agents across software projects.

## Why I built this

I built this after working with AI coding agents day to day and repeatedly running into the same problems.

They were fast, but they had a tendency to over-engineer solutions, introduce abstractions that weren't necessary and make changes that looked reasonable in isolation without fully understanding their effect on the rest of the codebase.

The more frustrating problems were the subtle ones. A change could appear perfectly sensible in a diff but introduce unexpected behaviour elsewhere because the agent hadn't understood an existing data flow, component lifecycle or architectural decision. Those issues often only surfaced when I manually tested the application, sometimes wiping out much of the time the AI was supposed to save.

Good engineering teams reduce these kinds of failures through planning, shared standards, specialist review, testing and accumulated knowledge. I wanted to see what happens when AI agents work with those same disciplines rather than treating every coding task as an isolated prompt.

This repository is my attempt at that: a reusable system for how agents plan, build, review, test and learn across software projects.

## What it does

The AI Engineering System provides a shared operating model for AI-assisted software development.

Instead of asking one agent to understand a request, make every decision, write the code and declare the result finished, the system separates those responsibilities.

It provides:

- engineering standards and guardrails;
- collaborative planning before implementation;
- specialist responsibilities for frontend, backend, platform, security and QA;
- work specifications and architectural decision records;
- deterministic quality gates;
- independent review;
- project-level knowledge and regression tracking;
- and a learning process for turning failures and discoveries into durable knowledge.

The goal isn't to make agents generate more code. It's to make AI-assisted engineering more deliberate, verifiable and cumulative.

## Core principles

### Agents have autonomy over implementation, not authority over intent

Once requirements and architecture are agreed, implementation agents should be able to work without asking about every small coding decision.

They shouldn't silently redefine the product, architecture, security model or other important human decisions.

### Planning comes before implementation

Planning is a collaborative engineering activity, not just prompt preparation.

Requirements, assumptions, architecture, risks and acceptance criteria should be understood before implementation begins.

### Challenge assumptions

A proposed solution is input to the discussion, not automatically the correct implementation.

When realistic alternatives exist, the system should explain the trade-offs and recommend an approach rather than simply agreeing.

### Local correctness isn't enough

Code can look perfectly reasonable in isolation and still be wrong within the wider system.

Agents need enough project context to consider existing architecture, data flows, state, side effects, security boundaries and established behaviour before changing them.

### Prefer evidence over confidence

Tests, builds, linters, security tools and performance measurements are stronger evidence than an agent saying something looks correct.

If a required check hasn't run, the system shouldn't claim it passed.

### Independent review matters

The model that implemented a change shouldn't be treated as genuinely independent evidence that the change is correct.

Important changes should pass automated validation and, where configured, independent review from a different provider before final human acceptance.

### Prefer the simplest solution that meets the requirements

Avoid speculative abstractions, unnecessary dependencies, unrelated refactors and architecture designed for hypothetical future problems.

Simplicity matters, but not at the expense of security, correctness or reliability.

### Humans retain high-impact authority

Agents can have substantial autonomy without having unlimited authority.

Architectural uncertainty, destructive operations, releases, merges and other consequential actions should return to a human when appropriate.

## How it works

A typical piece of work moves through a lifecycle like this:

```text
Conversation
    ↓
Planning
    ↓
Work specification
    ↓
Human approval
    ↓
Implementation
    ↓
Automated quality gates
    ↓
Security / QA
    ↓
Independent review
    ↓
Human acceptance
    ↓
Learning
```

The exact workflow depends on the type and risk of the change, but the principle remains the same: **understand the work, implement it, prove it and preserve what was learned.**

## Specialist responsibilities

The system separates different engineering concerns rather than expecting one agent to reason equally well about everything at once.

- **Planning** clarifies requirements, challenges assumptions, explores architecture and produces an agreed work specification.
- **Orchestration** coordinates approved work, dependencies, specialists and quality gates.
- **Frontend** focuses on UI architecture, accessibility, browser behaviour, performance and design fidelity.
- **Backend** focuses on APIs, data, authentication, authorisation, concurrency, reliability and scalability.
- **Platform** covers infrastructure, cloud architecture, networking, deployment, observability, capacity and recovery.
- **Security** reviews changes adversarially and looks for ways assumptions and boundaries can fail.
- **QA** validates the implementation against acceptance criteria and real test evidence.
- **Learning** turns useful discoveries, failures and regressions into durable project knowledge.
- **Independent review** provides a separate challenge after implementation rather than allowing the implementing agent to review itself.

The detailed responsibilities live under [`agents/`](agents/).

## Engineering standards

The system applies a shared set of engineering guardrails across projects.

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

The detailed standards live under [`rules/`](rules/), covering architecture, security, scalability, accessibility, testing, reliability, frontend, backend, platform and code quality.

## Project knowledge

The global system describes **how software should be engineered**.

Each application separately records **what that particular system is and why it works the way it does**.

A consuming project can maintain durable knowledge under `.agents/`:

```text
.agents/
├── project/
│   ├── system-overview.md
│   ├── architecture/
│   ├── domains/
│   ├── data/
│   └── design/
├── decisions/
├── specs/
│   ├── active/
│   └── archive/
├── learnings/
├── failures/
└── regressions/
```

This gives agents relevant project context without forcing every future session to reconstruct the application from conversation history.

**Repository files are durable memory. Conversation history is temporary working context.**

## Work specifications and decisions

Each meaningful feature, bug fix, migration, refactor or architectural change can have its own work specification.

A specification captures the objective, requirements, important decisions, risks, tests and acceptance criteria for that piece of work.

Long-lived architectural decisions belong in ADRs rather than disappearing into a chat transcript.

Templates are provided under [`templates/`](templates/).

## Learning from mistakes

One of the main goals of the system is to avoid paying repeatedly for the same mistake.

Implementation failures, incidents, security findings, regressions, review findings and human corrections can produce durable learnings.

Those learnings may eventually become:

- project knowledge;
- an ADR;
- a regression test or record;
- or a proposed engineering guardrail.

They don't automatically rewrite the rules. Permanent guardrails should be deliberate, reviewed decisions rather than an accumulation of reactions to individual failures.

## Context and token efficiency

More context isn't automatically better.

The system aims to use the minimum reasoning and context necessary to complete work reliably, using techniques such as:

- progressive disclosure;
- relevant project knowledge rather than entire histories;
- deterministic tools for deterministic questions;
- concise work specifications;
- explicit task state;
- bounded retries;
- parallel work where it is genuinely independent;
- and compressed durable learnings.

The objective isn't the lowest token usage at any cost. It's the **lowest practical cost per successfully completed engineering task at the required quality**.

## Model routing

Models are selected according to task complexity and risk rather than permanently tied to job titles.

A sensible starting point is:

```text
Planning / complex architecture / security
    → high-reasoning model

Routine implementation / orchestration / QA / learning
    → capable execution model

Lint / format / typecheck / tests / builds / security scans
    → deterministic tools

Pull-request review
    → independent provider
```

Routing should evolve as model capabilities change rather than hard-coding today's model names into the architecture.

## Using v0.1

v0.1 is the **reference architecture** for the AI Engineering System.

It defines the engineering standards, responsibilities, workflows, project knowledge structure and model-routing approach that the system is built around.

It can be used as a reference for establishing AI-assisted engineering practices, but it doesn't yet provide a packaged installation or automated setup process.

To explore it:

1. Start with [`AGENTS.md`](AGENTS.md) for the system's core instructions.
2. Explore [`agents/`](agents/) for specialist responsibilities.
3. Review [`rules/`](rules/) for the engineering guardrails.
4. See [`workflows/`](workflows/) for the lifecycle of different types of change.
5. Use [`templates/`](templates/) for work specifications, ADRs, learnings and regressions.
6. See [`project-structure.md`](project-structure.md) for the suggested structure of a consuming project's knowledge.

## Repository structure

```text
ai-engineering-system/
├── AGENTS.md
├── README.md
├── agents/                 # specialist responsibilities
├── rules/                  # engineering guardrails
├── workflows/              # change lifecycles
├── templates/              # specs, ADRs and learning records
├── models/                 # model policy and routing
├── tooling/                # quality, security and infrastructure guidance
├── project-structure.md    # consuming-project knowledge structure
└── versions/
    └── CHANGELOG.md
```

## What's next

### v0.1 — reference architecture

The current `main` branch establishes the principles, roles, guardrails, workflows and knowledge model.

### v0.2 — Claude Code integration

v0.2 turns the reference architecture into an executable Claude Code integration.

It introduces native agents and skills, project setup, deterministic quality gates, approval guardrails, progressive context loading and a provider-neutral independent-review integration.

v0.2 is currently under development and will replace the v0.1 reference implementation on `main` when it has completed review and release.

Once the v0.2 branch is public, this section will link directly to it.

## Philosophy

AI makes writing code faster. That doesn't remove the need for engineering discipline; it makes that discipline more important.

The aim of this project is to give agents enough autonomy to be genuinely useful while surrounding that autonomy with planning, context, verification, independent challenge and human judgement.

A good result isn't simply that the agent produced working code quickly.

It's that the right thing was built, the implementation fits the wider system, important claims were verified, unintended consequences were considered and useful knowledge survives for the next piece of work.

## About

Built by **[Ashley Oliver](https://www.linkedin.com/in/ashleyioliver/), Senior Product Engineer**.

I build software products and explore how AI-assisted engineering can become more reliable, maintainable and effective in real-world development.
