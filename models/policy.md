# Model Routing Policy

Use the least expensive model capable of reliably completing the task.

## Starting tiers
- reasoning: Claude Opus 5.5 (configurable) for architecture, ambiguous planning, high-risk security reasoning, complex failures, major infrastructure design.
- execution: Claude Sonnet 5.5 (configurable) for routine implementation, orchestration, QA, learning, and routine platform work.
- deterministic: tools for formatting, lint, typecheck, tests, builds, scans, Lighthouse, IaC validation, and load tests.

Model choice depends on task complexity, ambiguity, risk, and expected cost per successful task—not agent seniority.

Use a small retry budget. Escalate when repeated attempts make no meaningful progress.

Measure success, attempts, tokens, cost, duration, human corrections, review findings, and regressions. Optimise cost per successful task.
