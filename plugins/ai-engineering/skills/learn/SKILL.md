---
name: learn
description: Capture durable knowledge from a failure, incident, review finding, feedback or discovery into .agents/ via the learning agent, and propose (never apply) global guardrail changes.
argument-hint: "[what happened]"
disable-model-invocation: true
---
# Learn

1. Gather the facts: what happened, evidence (commands, outputs, findings, links), root cause if known, and what should change. Use `$ARGUMENTS` and the current conversation; ask the user only for missing facts that matter.
2. Delegate to `ai-engineering:learning` with those facts and the relevant template path:
   - Learning: `${CLAUDE_SKILL_DIR}/templates/learning.md`
   - Regression: `${CLAUDE_SKILL_DIR}/templates/regression.md`
   - Incident: `${CLAUDE_SKILL_DIR}/templates/incident.md`
3. If the lesson should become a project rule, present the proposed wording for the human to add to `AGENTS.md`; the learning agent cannot edit it.
4. If a must-never-break behaviour has no regression test yet, list the test that should be written; implementing it is normal delivery work.
5. Report what was written and where.

Global guardrails are never changed automatically. If the learning agent marks a lesson `Scope: General (proposed guardrail)`, present the proposed rule to the user. Promotion happens only through a reviewed pull request to the ai-engineering system repository.
