# AI Engineering System

A reusable, self-improving engineering system for planning, building, reviewing, testing and learning with AI agents across software projects.

## Why I built this

I built this after working with AI agents day to day and repeatedly running into the same problem: they're incredibly fast, but speed doesn't automatically produce good engineering.

An agent can agree with a bad plan, skip an important test, repeat a previous mistake or make a locally sensible change that creates problems elsewhere.

Good engineering teams reduce those failures through planning, shared standards, specialist review, testing and accumulated knowledge. I wanted to explore what happens when AI agents work with those same disciplines.

This repository is my attempt at that: a reusable engineering system for how agents plan, build, review, test and learn across software projects.

---

## The idea

AI coding tools are very good at generating code.

That is not the same thing as engineering software well.

Reliable software development also requires:

- understanding the problem before implementing it;
- challenging weak assumptions;
- making deliberate architectural decisions;
- applying consistent engineering standards;
- considering security and failure modes;
- testing meaningful behaviour;
- reviewing work independently;
- validating performance and accessibility;
- preserving useful project knowledge;
- learning from failures and regressions;
- and knowing when a human decision is required.

The AI Engineering System provides a reusable structure for those responsibilities.

The aim is not to create a collection of personas that generate more conversation. The aim is to create an engineering process in which different responsibilities are explicit, important decisions are durable, quality can be verified and agents become more effective as a project develops.

---

## Core principles

### Agents have autonomy over implementation, not authority over intent

Once requirements and architecture are agreed, implementation agents should be able to work without asking about every minor coding decision.

They should not silently redefine the product, architecture, security model or other important human decisions.

### Planning comes before implementation

The system treats planning as a collaborative engineering activity rather than a prompt-writing exercise.

Requirements, assumptions, architecture, risks and acceptance criteria should be understood before implementation begins.

### Challenge assumptions

Agents should not automatically agree with a proposed solution.

A proposed implementation is input to the discussion unless it has explicitly been declared a final constraint.

Where multiple realistic approaches exist, the system should explain the trade-offs and recommend one.

### Prefer evidence over confidence

Tests, builds, linters, security tools, performance measurements and other deterministic checks are stronger evidence than an agent saying something looks correct.

If a required check has not been run, the system should say so.

### Independent review matters

The same model that implemented a change should not be treated as genuinely independent evidence that the change is correct.

Important changes should pass automated validation and, where configured, independent review from a different provider before final human acceptance.

### Humans retain high-impact authority

Destructive production operations, releases, merges and other high-impact actions should remain explicit human decisions.

Automation should reduce repetitive work without quietly taking control of consequential decisions.

### Simplicity wins

Prefer the simplest implementation that satisfies the requirements.

Avoid speculative abstractions, unnecessary dependencies, unrelated refactors and architecture designed for hypothetical future problems.

---

## Engineering priorities

When priorities conflict, use this order:

1. Security
2. Correctness
3. Reliability
4. Scalability
5. Accessibility
6. Maintainability and readability
7. Performance
8. SEO
9. Simplicity

Simplicity remains important throughout, but it must not come at the expense of security, correctness or reliability.

---

## How the system is organised

The system separates reusable engineering knowledge from project-specific knowledge and from the requirements of an individual piece of work.

### Global engineering system

Defines **how software should be engineered**.

It contains:

- engineering rules;
- specialist agent responsibilities;
- workflows;
- templates;
- model-routing policy;
- quality expectations;
- security expectations;
- testing standards;
- infrastructure guidance;
- and learning conventions.

### Project context

Defines **what a particular application is**.

Project knowledge belongs with the application rather than in the global engineering system.

Examples include:

- system architecture;
- domains and boundaries;
- data models;
- infrastructure;
- design conventions;
- important decisions;
- project-specific constraints;
- known regressions;
- and accumulated learnings.

### Work specifications

Define **what is changing now**.

Each meaningful feature, bug fix, migration, refactor or architectural change should have its own work specification rather than relying on a long conversation history.

### Architectural Decision Records

ADRs explain **why an important architectural decision was made**.

They are appropriate when:

- several viable approaches exist;
- the choice has lasting consequences;
- security or performance is materially affected;
- a non-obvious abstraction or dependency is introduced;
- or a future engineer might reasonably ask why the simpler-looking option was rejected.

### Learnings and regressions

Learnings capture durable discoveries.

Regressions capture behaviour that must not break again.

The objective is to turn mistakes and discoveries into reusable project knowledge rather than repeatedly paying to rediscover them.

---

## Agent responsibilities

The system divides engineering responsibilities into focused roles.

### Planning

Planning is the main conversational interface.

It:

- clarifies requirements;
- challenges assumptions;
- explores architecture;
- explains unfamiliar concepts;
- compares realistic options;
- recommends approaches;
- identifies open decisions;
- creates work specifications;
- creates ADRs when necessary;
- and establishes acceptance criteria.

Planning should distinguish between:

- `DECIDED`
- `OPEN`
- `ASSUMPTION`
- `NEEDS_HUMAN_DECISION`

Planning does not simply convert the user's first proposed solution into an implementation instruction.

### Orchestration

Orchestration coordinates approved work.

It:

- tracks dependencies;
- routes work to appropriate specialists;
- manages workflow state;
- runs deterministic quality gates;
- handles failures;
- escalates unresolved architectural questions;
- and enforces human decision boundaries.

The orchestrator should remain lightweight. It coordinates work rather than duplicating specialist reasoning.

### Frontend

Frontend responsibilities include:

- semantic HTML;
- accessibility;
- keyboard interaction;
- responsive behaviour;
- component and feature architecture;
- loading, error, empty and success states;
- browser behaviour;
- client/server boundaries;
- performance;
- Core Web Vitals;
- SEO;
- SSR and hydration concerns;
- and design fidelity.

Where Lighthouse applies, the target is at least **98** across Performance, Accessibility, Best Practices and SEO.

### Backend

Backend responsibilities include:

- authentication and authorisation;
- input validation;
- API contracts;
- data models and indexes;
- transactions;
- concurrency;
- idempotency;
- pagination and bounded result sets;
- queues and background jobs;
- rate limits;
- resource limits;
- timeouts;
- bounded retries;
- caching;
- observability;
- and load/concurrency behaviour.

Systems expected to operate at significant scale should be designed and tested accordingly rather than relying on unverified claims about capacity.

### Platform

Platform is a first-class engineering responsibility rather than an afterthought.

It covers areas such as:

- cloud architecture;
- networking and VPC design;
- subnets and routing;
- security groups;
- load balancers;
- compute platforms;
- databases;
- caching;
- object storage;
- CDNs;
- DNS;
- IAM;
- encryption and key management;
- secrets;
- WAFs;
- monitoring and logging;
- queues and events;
- CI/CD;
- infrastructure as code;
- autoscaling;
- deployment strategies;
- rollback;
- backups;
- disaster recovery;
- capacity;
- reliability;
- and infrastructure cost.

Infrastructure architecture should be discussed and agreed before implementation where meaningful choices exist.

High-impact production operations require explicit human approval.

### Security

Security review is adversarial.

It should actively look for:

- authentication failures;
- authorisation failures;
- IDOR/BOLA;
- privilege escalation;
- injection;
- XSS;
- CSRF;
- SSRF;
- secret exposure;
- data leakage;
- session weaknesses;
- recovery weaknesses;
- rate-limit bypasses;
- abuse paths;
- resource exhaustion;
- race conditions;
- supply-chain risks;
- excessive IAM permissions;
- unintended public exposure;
- and sensitive logging.

Security-sensitive behaviour should have negative tests, not merely happy-path tests.

### QA

QA validates the implementation against the agreed requirements.

It covers:

- acceptance criteria;
- meaningful automated tests;
- integration testing;
- end-to-end testing;
- regression testing;
- visual behaviour where relevant;
- build readiness;
- and evidence that required checks actually ran.

A typical validation progression is:

```text
unit/component
      ↓
integration
      ↓
targeted regression
      ↓
critical end-to-end
      ↓
broader regression where warranted
```

### Learning

The learning responsibility turns useful discoveries into durable knowledge.

Sources include:

- implementation failures;
- incidents;
- human feedback;
- security findings;
- review findings;
- regressions;
- architectural discoveries;
- and repeated patterns.

A learning may result in:

- project knowledge;
- an ADR;
- a regression record;
- or a proposed project/global engineering rule.

Learnings should be concise and should not accumulate as an unstructured history.

---

## Independent review

Independent review is deliberately separate from implementation.

The intended flow is:

```text
Planning
    ↓
Implementation
    ↓
Automated quality gates
    ↓
QA / security validation
    ↓
Pull request
    ↓
Independent review provider
    ↓
Findings and rework
    ↓
Human acceptance
```

Review findings can be classified as:

- `BLOCKER`
- `HIGH`
- `MEDIUM`
- `LOW`
- `NIT`

`BLOCKER` and `HIGH` findings normally require rework before acceptance.

An independent review finding should not automatically become a permanent engineering rule. Repeated or important findings should first be distilled into a learning and reviewed before being promoted.

---

## Work specifications

A work specification belongs to one meaningful unit of work, such as:

- a feature;
- bug fix;
- migration;
- refactor;
- infrastructure change;
- security change;
- or architectural change.

A specification can include:

- objective;
- scope;
- requirements;
- business rules;
- architecture;
- data;
- APIs;
- UI behaviour;
- security;
- scalability;
- reliability;
- observability;
- tests;
- risks;
- acceptance criteria;
- definition of done;
- and applicable guardrail version.

The lifecycle is:

```text
Draft
  ↓
Approved
  ↓
In Progress
  ↓
Implemented
  ↓
Verified
  ↓
Archived
```

Specifications are not permanent project documentation.

Once work is complete, lasting knowledge should be distilled into the appropriate project context, ADR, learning, regression or engineering rule.

---

## Concurrent work

The system is designed to support multiple unrelated pieces of work at the same time.

For example:

```text
WORK-001  SSO and MFA
WORK-002  Billing redesign
WORK-003  Production infrastructure
```

Each work item should maintain its own:

- objective;
- decisions;
- open questions;
- architecture;
- acceptance criteria;
- and state.

Shared project context and ADRs remain available to all work items.

Independent implementation work should use separate branches or worktrees where appropriate.

The orchestrator should identify shared dependencies or conflicting changes rather than assuming every work stream is independent.

---

## Engineering guardrails

### Code quality

Code should be:

- descriptive;
- explicit;
- readable;
- unsurprising;
- and as simple as the requirements allow.

Avoid:

- hypothetical abstractions;
- unnecessary dependencies;
- global dumping grounds;
- unrelated refactors;
- and cleverness that makes behaviour harder to understand.

When Biome is configured, it is the authoritative formatter/linter.

### Architecture

Prefer feature- or domain-encapsulated architecture.

Related behaviour should live together.

Avoid allowing generic `utils`, `services`, `helpers` or similar directories to become unstructured dumping grounds.

### Security

Treat all external input as untrusted.

Authentication does not imply authorisation.

Never commit secrets.

Security-sensitive behaviour should include negative tests.

### Scalability

Avoid unbounded:

- queries;
- result sets;
- memory use;
- request sizes;
- concurrency;
- `Promise.all`;
- retries;
- queues;
- fan-out;
- and transaction duration.

Use appropriate:

- pagination;
- batching;
- bounded concurrency;
- indexes;
- atomic operations;
- transactions;
- idempotency;
- caching;
- queues;
- rate limiting;
- backpressure;
- timeouts;
- and bounded retries.

Consider:

- connection-pool exhaustion;
- lock contention;
- retry storms;
- duplicate delivery;
- process restarts;
- and deployment behaviour.

Do not hold long-running database transactions around slow external calls unless there is a specific and justified reason.

### Accessibility

Prefer native semantic HTML.

Use appropriate:

- labels;
- alternative text;
- heading structure;
- focus behaviour;
- keyboard support;
- and DOM semantics.

Use ARIA when native semantics cannot express the required behaviour, not as a substitute for semantic HTML.

### Reliability

Design for:

- failures;
- timeouts;
- partial success;
- duplicate requests;
- retries;
- restarts;
- and deployments.

Errors should be explicit and observable.

Do not silently swallow failures.

### Testing

Tests should validate meaningful behaviour rather than implementation trivia.

Consider:

- expected behaviour;
- error paths;
- edge cases;
- business rules;
- authentication;
- authorisation;
- security boundaries;
- concurrency;
- regressions;
- and load where relevant.

Never claim a test or quality check passed unless it actually ran.

If a required check cannot be run, report:

```text
NOT VERIFIED: <reason>
```

---

## Definition of done

A change is not complete merely because code has been written.

Depending on the work, completion includes:

- implementation complete;
- meaningful automated tests;
- security considered;
- scalability considered;
- lint/format checks;
- type checking;
- production build;
- Lighthouse where applicable;
- load testing where applicable;
- final diff review;
- independent review where configured;
- and human acceptance.

The exact gates depend on the project and the risk of the change.

---

## Model routing

Models should be selected according to the complexity and risk of the task rather than permanently tied to job titles.

A sensible starting configuration is:

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

Routing should remain configurable as models improve.

The objective is not to minimise token price.

The objective is to minimise the **cost per successfully completed engineering task** while maintaining the required quality.

Useful measures include:

- task success;
- retries;
- tokens;
- cost;
- duration;
- human corrections;
- regressions;
- and review findings.

---

## Context and token efficiency

Context is a limited engineering resource.

The system should use the minimum model reasoning and context necessary to complete a task reliably — not the fewest tokens at any cost.

Principles include:

- load information progressively;
- provide only relevant project knowledge;
- separate stable context from dynamic task context;
- use deterministic tools where possible;
- summarise large logs before expanding them;
- maintain explicit task state to avoid repeated discovery;
- parallelise independent work;
- use rule-based orchestration where reasoning is unnecessary;
- stop retry loops and escalate after repeated failure;
- stop when the task is complete and required gates pass;
- keep work specifications concise;
- separate instructions, context, task and evidence;
- and compress duplicate learnings.

**Repository files are durable memory. Conversation history is temporary working context.**

Important decisions, constraints, architecture and learnings should therefore be written into the repository rather than depending on a particular conversation remaining available.

---

## Project knowledge

Each consuming application can maintain its own `.agents/` directory:

```text
.agents/
├── project/
│   ├── system-overview.md
│   ├── architecture/
│   │   ├── overview.md
│   │   ├── frontend.md
│   │   ├── backend.md
│   │   └── infrastructure.md
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

This keeps reusable engineering policy separate from application-specific facts.

---

## Repository structure

v0.1 is organised as:

```text
ai-engineering-system/
├── AGENTS.md
├── README.md
├── agents/
│   ├── planning.md
│   ├── orchestrator.md
│   ├── frontend.md
│   ├── backend.md
│   ├── platform.md
│   ├── security.md
│   ├── qa.md
│   ├── learning.md
│   └── independent-review.md
├── rules/
│   ├── core.md
│   ├── architecture.md
│   ├── security.md
│   ├── scalability.md
│   ├── frontend.md
│   ├── backend.md
│   ├── platform.md
│   ├── testing.md
│   ├── accessibility.md
│   ├── reliability.md
│   └── quality.md
├── workflows/
│   ├── feature.md
│   ├── bug-fix.md
│   ├── refactor.md
│   ├── release.md
│   ├── infrastructure.md
│   ├── security-change.md
│   └── architecture-change.md
├── templates/
│   ├── work-spec.md
│   ├── ADR.md
│   ├── planning-session.md
│   ├── learning.md
│   ├── incident.md
│   ├── regression.md
│   └── project-AGENTS.md
├── models/
│   ├── policy.md
│   ├── routing.yaml
│   └── evaluation.md
├── tooling/
├── project-structure.md
└── versions/
    └── CHANGELOG.md
```

---

## Using v0.1

v0.1 is the **reference architecture** for the AI Engineering System.

It defines the engineering standards, specialist responsibilities, workflows, project knowledge structure and model-routing approach that the system is built around.

It is useful as a reference when establishing AI-assisted engineering practices in a project, but it does not yet provide a packaged installation or automated setup process.

To apply the ideas manually:

1. Use `AGENTS.md` as the entry point for the engineering system.
2. Keep application-specific instructions in the application's own `AGENTS.md`.
3. Create the `.agents/` structure in the consuming project for architecture, decisions, work specifications, learnings and regressions.
4. Use the templates in `templates/` for work specifications, ADRs and durable learnings.
5. Apply the relevant engineering rules and workflow to each piece of work.
6. Run the project's real quality checks rather than relying on agent judgement alone.
7. Preserve important decisions and discoveries in repository files.

v0.2 builds on this foundation with a native Claude Code integration, including installable agents and skills, project setup, deterministic quality gates, approval guardrails and independent-review integration.

Until v0.2 is released, `main` remains the stable v0.1 reference.

---

## Status

### v0.1

v0.1 establishes the reference architecture:

- engineering standards;
- specialist responsibilities;
- planning and delivery lifecycle;
- project knowledge structure;
- work specifications;
- ADRs;
- learning and regression capture;
- model-routing principles;
- independent-review expectations;
- and context-efficiency principles.

### v0.2

v0.2 is the next step: turning the reference architecture into a practical Claude Code integration.

The work focuses on making the system executable rather than simply descriptive, while retaining the principles established in v0.1.

---

## Philosophy

The goal is not to make AI agents write more code.

The goal is to make AI-assisted engineering more disciplined, reliable and cumulative.

A useful engineering system should help agents:

- think before implementing;
- challenge questionable decisions;
- use specialists where they add value;
- prove important claims with tools;
- recognise when human judgement is required;
- learn from failures;
- preserve useful knowledge;
- and avoid paying repeatedly for the same mistake.

The system should become more useful as a project develops without requiring every future agent to read the entire history of how the project got there.

Good engineering is not just implementation speed.

It is the combination of sound decisions, clear code, meaningful verification, independent challenge and accumulated knowledge.
