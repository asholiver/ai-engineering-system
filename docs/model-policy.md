# Model Routing Policy

Use the least expensive model capable of reliably completing the task.

## Source of truth
The `model` (and optional `effort`) field in each agent's frontmatter under `plugins/ai-engineering/agents/` is the only routing configuration. Do not restate it elsewhere; `scripts/check.sh` prints the current routing. v0.2 uses model aliases (`sonnet`, `opus`), which follow the newest model in each family.

## Tiers
- reasoning (`opus`): architecture, ambiguous planning, high-risk security reasoning, complex failures, major infrastructure design. Planning runs in the main session on the session's model.
- execution (`sonnet`): routine implementation, orchestration, QA, learning and routine platform work.
- deterministic (tools, no model): formatting, lint, typecheck, tests, builds, scans, Lighthouse, IaC validation and load tests.

Model choice depends on task complexity, ambiguity, risk and expected cost per successful task, not agent seniority.

## Retries and escalation
- Implementation agents get at most 2 fix rounds when the fast gate fails: sent back by `/ai-engineering:deliver`, or, with `AI_ENGINEERING_HOOK_GATES=1`, enforced by `gate-fast.sh`, which then has the agent report `GATE FAILED`.
- `/ai-engineering:deliver` may retry once on the reasoning tier (`model: "opus"` on the call), then escalates to the human.

## Evaluation
Track per task where available: task type, model and effort, input/output/cache tokens, cost, duration, attempts, success or failure, human intervention, independent review findings and regressions. Compare by successful-task cost and reliability, not token price alone. Do not change routing from one task; use aggregated evidence.
