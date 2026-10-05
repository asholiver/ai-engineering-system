---
name: engineering-standards
description: Core engineering non-negotiables for all work - authority boundaries, evidence, code quality, architecture, security baseline, reliability, scalability, testing and context efficiency. Injected at session start and preloaded into every ai-engineering agent.
user-invocable: false
---
# Engineering Standards

Priorities, in order: security, correctness, reliability, scalability, accessibility, maintainability, performance, SEO where applicable, simplicity.

## Authority
- Agents have autonomy over implementation, not authority over intent. The human owns product intent and major architectural, security, destructive and materially costly decisions: escalate these instead of deciding them.
- Inspect before changing. Reuse established patterns. Keep changes focused; no unrelated refactors.
- Record durable decisions as ADRs and lessons under `.agents/` so they are not rediscovered.

## Evidence
- Never claim a check passed unless it was run; report the command and its result.
- Prefer deterministic tools (formatters, linters, type checkers, tests, scanners, builds) over model reasoning for deterministic questions. Reasoning is not a substitute for executing tests.
- Work is not done until implementation, required tests, quality/security checks and the build pass.

## Code and architecture
- Prefer the smallest correct solution. No speculative abstractions, layers or dependencies.
- Human-readable code with descriptive names; no cryptic abbreviations such as `const t = c`.
- Prefer feature/domain encapsulation: keep a feature's components, tests, styles, schemas and helpers together. Share only what is genuinely reused.
- When the project configures a formatter or linter (for example Biome), it is authoritative.

## Security baseline
- Treat external input as untrusted. Authentication is not authorization.
- Never commit credentials or log sensitive data unnecessarily.
- Security-sensitive behavior requires negative tests. Deeper guidance: `security-standards`.

## Reliability and scalability
- Assume networks, databases, APIs, queues, caches and processes fail. Use timeouts, bounded retries, safe idempotency, graceful shutdown, explicit failure handling and useful observability. Never silently swallow meaningful errors.
- Design beyond the smallest working load. Avoid unbounded memory, queries, results, fan-out, retries, queues, request sizes, external calls, transaction duration and cache size. Use pagination, indexes, batching, bounded concurrency, rate limiting and backpressure where appropriate.
- Consider connection pools, lock contention, retry storms, duplicate requests, restarts, deploys during traffic and downstream failures. Working for 5 concurrent requests does not make a design acceptable for 100,000+.

## Testing
- Meaningful functionality requires meaningful tests: behavior, business rules, error paths, edge cases, authorization, concurrency and integrations as relevant.
- Choose unit, integration, E2E, regression, security and load testing according to risk. Add regression coverage for defects where practical.

## Context efficiency
- Load only the rules, playbooks and project knowledge relevant to the task. Keep specs concise; retrieve relevant learnings rather than all history.
- Summarise tool output and expand on demand. Use bounded retries; escalate when attempts stop making progress. Stop when gates are satisfied.
- Optimise for cost per successfully completed task, not minimum tokens at any cost.
