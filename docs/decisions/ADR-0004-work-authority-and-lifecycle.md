# ADR-0004: Work authority lives in state, not conversation
## Status
Accepted (by Ashley Oliver, 2026-10-06) as part of the v0.3 architecture. Implemented by work spec `WORK-002`. Takes effect on release of v0.3.0. Includes owner decisions D1–D3 of 2026-10-06.
## Context
In the Landra F0 dogfood, authority was inferred from conversation:
- about 25 of 36 human prompts were approve, decide or continue;
- about 69% of the elapsed time was waiting on the owner;
- one conversational remark ("update the readme") was treated as authority to change files before delivery was authorised.

The specification mixed intent with roughly 450 lines of delivery state that every agent re-read. Specialists ran Git commands. Waits on external systems ran inside the model, and one stall needed a manual resume.

Governing principle: agents have autonomy over implementation, not authority over intent.
## Decision
- **One state file per work item.**
  - `.agents/specs/active/WORK-NNN.state.json` holds the lifecycle status, approval, delivery authority and policy, increments, decisions, planned owner actions, tiers and the review ledger.
  - Only a single transition script changes it.
  - The spec (`WORK-NNN.md`) holds intent only. The append-only narrative goes in `WORK-NNN.log.md`, which isn't loaded by default.
- **Lifecycle** (the normative transition table is in `WORK-002`):
  ```text
  proposed → approved → authorised → delivering → done → archived
  delivering → blocked → delivering
  authorised | delivering | blocked → paused → (owner resumes) → the status it was paused from
  any change to the spec content → proposed
  ```
  Only `delivering` leads to `done`. `blocked` and `paused` never lead directly to `done`.
  - Approving and authorising are owner-only transitions.
  - So are accepting or waiving risk, lowering a tier, extending scope and revoking.
  - Approval binds a spec content hash. Any change to the spec returns the item to `proposed`.
- **Verifiable owner transitions without new prompts.**
  - A silent, non-blocking `UserPromptExpansion` hook records a one-time authority token when the owner types a human-only lifecycle command. `UserPromptExpansion` fires only for slash commands the human types. `UserPromptSubmit` is not used, because it also fires for scheduled tasks, background-subagent reports and cross-session messages.
  - The transition script refuses owner-only transitions without a fresh matching token.
  - Conversation alone never grants authority.
  - There are two human-only commands:
    - `/ai-engineering:approve` approves a spec, accepts or waives a finding's risk, lowers a tier, or revokes;
    - `/ai-engineering:deliver` authorises or resumes delivery.

    Approval and delivery authorisation stay distinct: neither command's token can perform the other's transitions.
- **Delivery policy is part of the approved spec**, including:
  - autonomous work-branch pushes;
  - autonomous ephemeral preview deployments when the accounts and credentials already exist;
  - any persistent environments explicitly authorised.

  Production deployment, merging, releasing, publishing, default-branch pushes, destructive operations, and creating or changing credentials, accounts or consequential external resources always stay with the owner.
- **Five escalation triggers** are the only reasons to interrupt the owner after authorisation:
  1. intent or scope;
  2. an owner-level trade-off, new dependency or new external service;
  3. accepting risk;
  4. a reserved operation;
  5. a genuine ambiguity that changes what gets built.
- **Remediation depends on what resolving a finding involves, not on its severity.**
  - A fix inside the approved intent is made autonomously at any severity.
  - HIGH-or-above fixes are listed in the readiness report.
  - Accepting, waiving or deferring risk is always an owner decision.
- **The coordinator owns Git.**
  - Specialists edit files and run tests. The guard denies their Git writes ([ADR-0003](ADR-0003-structured-action-guard.md)).
  - Tasks run in parallel worktrees by default. `/setup` sets `worktree.baseRef: "head"`, with a documented opt-out.
- **Lean handoffs, bounded recovery, waits outside the model.**
  - Specialists receive their task and a relevant excerpt of the spec, never the log.
  - A stalled agent is resumed automatically once, then escalated.
  - External waits run as bounded, authenticated background commands.
- **Removed:**
  - the duplicated Prove step (deliver uses the review procedure);
  - per-append learning-agent spawns;
  - playbook selection during delivery;
  - the setup question about worktrees;
  - "any open decision goes to the user".
## Why
State that only explicit owner commands can change makes the boundary between intent and implementation checkable and measurable. Routine work then needs no permission. Putting delivery policy in the approved spec moves one decision up front instead of asking many questions mid-delivery.
## Alternatives considered
### A pre-authorisation write-blocking hook
Not adopted initially (owner decision). Boundary crossings are measured instead. A blocking hook is reconsidered only if crossings occur.
### An extra confirmation prompt at `/deliver`
Rejected. The delivery policy is already in the approved spec, so `/deliver` shows it but doesn't ask again.
### Requiring a specific model for the coordinator
Rejected (owner decision D3). The coordinator is the main session, whose model the user chooses. Model routing stays in agent frontmatter, and Opus remains required where the risk policy calls for the Opus security reviewer.
### A custom orchestration runtime, Agent Teams or MCP
Rejected. They are unnecessary given native subagents, worktrees, background commands and hooks ([ADR-0001](ADR-0001-claude-native-architecture.md)).
## Consequences
- The owner types explicit lifecycle commands instead of conversational approvals.
- Tokens and state files can be forged by any process with shell access. They make authority tamper-evident and detect accidental drift; they don't defend against a deliberately adversarial agent. Reserved operations still pass through the guard and the platform's own controls (branch protection, environment approvals).
- Existing v0.2 work items need an import step. v0.2 delivery authority is never imported as v0.3 authority.
