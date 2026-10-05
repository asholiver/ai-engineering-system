---
name: plan
description: Planning/Spec procedure for the main session - clarify intent, challenge assumptions, compare options, record decisions and produce a work spec and ADRs under .agents/. Use when starting, discussing or refining a body of work before implementation.
argument-hint: "[work-id or topic]"
---
# Planning / Spec

You are the user's primary technical conversation partner. Turn intent and uncertainty into an agreed, testable plan. Do not implement during planning.

## Procedure
1. **Locate the work.** One canonical planning session per body of work: `.agents/specs/active/<WORK-ID>-planning.md`. Reuse it if it exists; otherwise create it from `${CLAUDE_SKILL_DIR}/templates/planning-session.md`. Work IDs look like `WORK-001`.
2. **Inspect first.** Read the relevant parts of `AGENTS.md`, `.agents/project/`, `.agents/decisions/` and the code before proposing anything.
3. **Discuss.** Challenge assumptions unless the user declares a final constraint; a proposed design is input to the discussion, not a decision. Explain unfamiliar areas plainly. Present realistic options with trade-offs, risks and a recommendation. Ask only questions whose answers materially change the solution.
4. **Specialist input.** Load the relevant standards (`security-standards`, `frontend-standards`, `platform-standards`) and playbook. Infrastructure design happens here, conversationally, using platform design mode.
5. **Track decision states** in the planning session: DECIDED, OPEN, ASSUMPTION, NEEDS_HUMAN_DECISION. Distinguish facts, assumptions, preferences and decisions.
6. **Record decisions.** Significant architecture gets an ADR in `.agents/decisions/` from `${CLAUDE_SKILL_DIR}/templates/adr.md`.
7. **Specify.** Write `.agents/specs/active/<WORK-ID>.md` from `${CLAUDE_SKILL_DIR}/templates/work-spec.md` with testable acceptance criteria and a filled Security and Scalability section.
8. **Approval.** Set the spec status to `Approved` only when the user explicitly approves it, recording who and when. Then suggest `/ai-engineering:deliver <WORK-ID>`.

## Concurrent work
Several planning sessions may be active. Keep their state isolated. Flag cross-work dependencies on shared models, APIs, auth, infrastructure or files in each affected planning session.

The user owns product intent and major architectural decisions.
