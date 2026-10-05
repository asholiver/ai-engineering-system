# AI Engineering System

A reusable, self-improving operating system for AI-assisted software engineering.

The AI Engineering System provides a shared engineering framework for AI agents working across software projects. It defines how agents should plan, implement, review, test, secure, deploy, and learn from engineering work while keeping project-specific knowledge inside each application repository.

The goal is not simply to make AI agents write more code. It is to make them behave like a coordinated engineering team that becomes more effective over time.

## Goals

The system is designed around several principles:

- high engineering quality by default
- security and correctness before convenience
- scalable architecture rather than happy-path implementations
- semantic, accessible and performant frontend development
- simple, human-readable code
- feature and domain-oriented architecture
- meaningful automated testing
- independent review
- explicit architectural decisions
- safe infrastructure and deployment practices
- efficient use of models, context and tokens
- durable learning from mistakes and discoveries
- support for multiple concurrent work streams

Agents have **autonomy over implementation, not authority over intent**.

## Engineering Lifecycle

The standard lifecycle is:

```text
Discuss
   ↓
Decide
   ↓
Specify
   ↓
Implement
   ↓
Prove
   ↓
Independent Review
   ↓
Human Acceptance
   ↓
Deploy
   ↓
Observe
   ↓
Learn
```

Not every change requires every stage, but stages should only be skipped deliberately.

## Agent Capabilities

### Planning / Spec

The primary conversational interface for engineering work.

Planning helps understand requirements, challenge assumptions, investigate the existing system, compare architectural options, explain technical concepts, identify risks and produce an agreed work specification.

The Planning Agent should not simply agree with a proposed implementation.

Unless something has been declared a final constraint, proposed architecture is treated as input to the discussion.

### Orchestrator

Coordinates approved work.

It manages dependencies, routes work to specialists, tracks execution state, runs deterministic quality gates and coordinates concurrent work streams.

The Orchestrator is deliberately lightweight. Architecture belongs primarily to Planning and the relevant specialists.

### Frontend

Responsible for:

- UI architecture
- semantic HTML
- accessibility
- responsive behavior
- component architecture
- state management
- browser behavior
- Core Web Vitals
- performance
- SEO
- SSR and hydration
- design fidelity

Applicable pages target Lighthouse scores of **98 or higher** for:

- Performance
- Accessibility
- Best Practices
- SEO

Audits must not be disabled simply to reach the target.

### Backend

Responsible for:

- API contracts
- authentication
- authorization
- validation
- data models
- indexes
- transactions
- concurrency
- idempotency
- pagination
- queues and background jobs
- rate limiting
- caching
- observability
- failure handling
- load and concurrency behavior

Systems should be designed with realistic growth and high concurrency in mind rather than only the smallest working load.

### Platform

Responsible for infrastructure and operational architecture.

This includes:

- cloud architecture
- AWS
- networking
- compute
- databases
- IAM
- secrets
- CDN and WAF
- DNS
- CI/CD
- autoscaling
- backups
- disaster recovery
- observability
- capacity
- deployment safety
- infrastructure cost

Infrastructure discussions are conversational.

The Platform Agent should explain unfamiliar infrastructure concepts, present realistic alternatives and recommend an approach before implementing major architectural decisions.

Infrastructure should normally be implemented through infrastructure as code and reviewed before application.

### Security

Provides adversarial security review.

Areas include:

- authentication and authorization
- IDOR / BOLA
- privilege escalation
- injection
- XSS
- CSRF
- SSRF
- secrets
- sensitive data
- session security
- abuse protection
- resource exhaustion
- race conditions
- supply-chain risks
- IAM
- infrastructure exposure

Security-sensitive behavior should include negative tests.

### QA

Responsible for proving that implementation satisfies the specification.

Testing is risk-based and can include:

```text
unit/component
    ↓
integration
    ↓
targeted regression
    ↓
critical E2E
    ↓
broader regression / load testing where required
```

AI reasoning is not a substitute for executing tests.

### Learning

Turns engineering experience into durable knowledge.

Sources include:

- implementation failures
- incidents
- human feedback
- security findings
- PR review findings
- regressions
- architectural discoveries
- repeated mistakes

Learnings can become:

```text
Project learning
ADR
Regression test
Project rule
Global engineering guardrail
```

Not every observation should become a permanent global rule.

Knowledge should be periodically compressed so the system becomes smarter without continuously increasing prompt size.

## Independent Review

Implementation should receive independent PR review where practical.

The preferred architecture is:

```text
Planning / Specialists
        ↓
Implementation
        ↓
Automated Quality Gates
        ↓
QA
        ↓
Pull Request
        ↓
Independent AI Reviewer
        ↓
Human Acceptance
```

The independent reviewer should ideally use a different model or provider from the implementation agents.

This provides a second perspective and reduces correlated reasoning failures.

## Concurrent Work

The system supports multiple unrelated work streams inside the same repository.

For example:

```text
WORK-001 — SSO + MFA
WORK-002 — Billing redesign
WORK-003 — AWS infrastructure
```

Each work stream maintains independent:

- planning
- decisions
- assumptions
- acceptance criteria
- implementation state
- tests
- review state

Implementation should use isolated branches or Git worktrees where appropriate.

The Orchestrator should detect when apparently independent work begins touching shared architectural areas.

## Project Knowledge

The engineering system contains reusable engineering behavior.

Application-specific knowledge remains inside the application repository.

Recommended structure:

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

This creates an important separation:

```text
Engineering System
    → How should we engineer software?

Project Context
    → How does this application work?

Work Specification
    → What are we changing now?

ADR
    → Why did we make this architectural decision?

Learning
    → What did we discover?

Regression
    → What must never break again?
```

## Model Routing

Models should not be permanently tied to job titles.

Instead, models are selected according to task complexity, ambiguity and risk.

A starting configuration might use:

Complex planning / architecture / security
    → high-reasoning model

Routine implementation / QA / orchestration
    → execution model

Lint / format / tests / build / scanning
    → deterministic tooling

PR review
    → independent provider

Routing is configured centrally under models/.

The objective is not minimum token usage at any cost.

The objective is:

Minimum cost per successfully completed engineering task.

Context and Token Efficiency

The system follows progressive disclosure.

Agents should load only the information required for the current task.

Stable engineering instructions, project architecture, current work state and execution evidence should remain separate.

Prefer:

concise specifications

targeted retrieval

cached stable context

deterministic tools

summarized logs

bounded retries

escalation when necessary

parallel execution of independent work

compressed durable learning

Repository files are durable memory.

Conversation history is temporary working context.

Repository Structure

ai-engineering-system/
├── AGENTS.md
├── agents/
├── rules/
├── workflows/
├── templates/
├── models/
├── tooling/
├── versions/
├── CONTRIBUTING.md
└── README.md

Status

Current version:

v0.1.0

This version establishes the engineering model, agent responsibilities, guardrails, workflows, knowledge model and model-routing strategy.

The next stage is provider integration, beginning with Claude Code.

That integration will connect these concepts to practical mechanisms such as:

CLAUDE.md

Claude Code subagents

skills

commands

hooks

permissions

worktrees

model routing

concurrent work sessions

automated quality gates

Philosophy

AI should not replace engineering discipline.

It should make engineering discipline easier to apply consistently.

The system therefore favors:

evidence over confidence, simplicity over unnecessary abstraction, explicit decisions over hidden assumptions, and durable learning over repeatedly solving the same problem.

Models should not be permanently tied to job titles.

Instead, models are selected according to task complexity,
