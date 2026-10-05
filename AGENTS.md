# AI Engineering System

Reusable operating rules for AI-assisted software engineering.

## Non-negotiables
- Security, correctness, reliability, scalability, accessibility, maintainability, performance, and applicable SEO are first-class concerns.
- Prefer the smallest correct solution. Do not over-engineer.
- Code must be human-readable; use descriptive names and avoid cryptic abbreviations.
- Use semantic markup and native controls where applicable.
- Applicable web pages target Lighthouse Performance, Accessibility, Best Practices, and SEO >=98 without suppressing audits.
- Prefer feature/domain encapsulation; shared code is shared only when genuinely reused.
- Meaningful functionality requires meaningful tests.
- Work is not done until implementation, required tests, quality/security checks, and build are complete and passing.
- Design for concurrency and growth; avoid unbounded work and resources.
- Never claim a check passed unless it was actually run.
- Prefer deterministic tools over LLM reasoning for deterministic checks.
- Use the least expensive model capable of reliably completing the task.
- Agents implement agreed intent but escalate major architectural, security, destructive, or materially costly decisions.
- Record durable decisions and lessons so future agents do not rediscover them.

## Context discipline
Load only relevant rules and project knowledge. Keep stable context separate from dynamic task context. Summarise evidence first and expand on demand.

## Lifecycle
Discuss → Decide → Specify → Implement → Prove → Independently Review → Accept → Deploy → Observe → Learn
