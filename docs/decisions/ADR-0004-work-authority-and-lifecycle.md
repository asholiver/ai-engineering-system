# ADR-0004: Work authority lives in state, not conversation
## Status
**Original accepted decision (2026-10-06; historical text, unchanged):**

Accepted (by Ashley Oliver, 2026-10-06) as part of the v0.3 architecture. Implemented by work spec `WORK-002`. Takes effect on release of v0.3.0. Includes owner decisions D1–D3 of 2026-10-06.

**Status clarification (2026-10-13):**
- **Accepted and unchanged:** the 2026-10-06 decision, except for its owner-transition mechanism. Authority lives in state, not conversation; the lifecycle, delivery policy, escalation triggers, remediation, Git ownership and lean handoffs stand.
- **Superseded:** the `UserPromptExpansion` authority-token mechanism (D1). It will not ship in v0.3.0 or any later release.
- **Proposed amendment, not accepted:** user-presence owner signatures replace the token mechanism. The amendment is approved in principle for design only. It needs a security review, G1 closure (the trusted approval path, currently OPEN, with a separate macOS approver account (G1-b) as the provisional architecture) and the owner's separate, explicit acceptance before implementation. Completing the security review does not by itself accept it. The trust anchor (O3) is deferred.
- **v0.3.0 release:** "Takes effect on release of v0.3.0" applies only to the parts of this ADR that are accepted and implemented by then. Neither the superseded token mechanism nor an unaccepted signed-approval implementation ships automatically with v0.3.0. Owner-only transitions do not ship without an accepted mechanism.
- The superseded 2026-10-06 text is kept below, marked as superseded.
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
  - Only a single transition script changes it. (Amended 2026-10-13: it is the only supported state-transition interface. Under the unrestricted-Bash threat model direct state edits remain possible; they grant no cryptographic authority, and protected operations verify signed authorisation rather than trusting state fields. See `WORK-002` Scope item 1.)
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
- **Verifiable owner transitions by owner signature** (proposed amendment, 2026-10-13; not accepted; see Status).
  - Owner authority is a signature by a user-presence key over an exact approval record (repository, work item, action and scope, spec commit and hash, expiry, and a nonce for transition approvals). The owner makes it through a trusted approval path; it is verified unattended against a trust anchor outside the agent's write reach.
  - There are two kinds. A **transition approval** is intended to be single-use and authorises one owner-only lifecycle transition; single use is not yet rollback-resistant (see the replay limitation in Consequences). A **delivery permission** is short-lived, names one increment and an explicit list of permitted actions, and may be reused until it expires; every use is verified afresh. Agent-writable state never expands authority, and no security property depends on agent-writable revocation state. Longer-lived permissions are open, and so is durable revocation: early revocation of an unexpired permission is not cryptographically enforceable today (see Consequences). When a permission is absent or expired, protected operations pause for fresh owner approval.
  - Provisional key placement: the private signing key isolated in a separate approver account (G1-b), with a root-owned verification anchor in the Claude-running account (installation deferred).
  - Each transition approval or delivery permission costs the owner one deliberate review and one authentication (Touch ID or password). A new increment, a new action scope or an expired permission can require another approval.
  - The trusted approval path (G1) is OPEN. Provisional architecture: a separate macOS approver account holding the key and signer (G1-b), which is not treated as secure until its proof of concept passes. G1 stays open until that proof of concept passes and the owner separately approves closing G1. Details and tests: `WORK-002`.
  - Guard rules on nested Claude launches and signer use are defence in depth, not the authority boundary.
  - Conversation alone never grants authority.
  - There are two human-only commands. Each creates a pending request and grants nothing until the owner signs:
    - `/ai-engineering:approve` approves a spec, accepts or waives a finding's risk, lowers a tier, or revokes. Revoking changes state only: it cannot invalidate an unexpired signed delivery permission (see the revocation limitation in Consequences);
    - `/ai-engineering:deliver` authorises or resumes delivery.

    Approval and delivery authorisation stay distinct: neither command's approval can perform the other's transitions.
- **Superseded 2026-10-13: Verifiable owner transitions without new prompts.** Kept as history; this mechanism will not ship.
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

  At a protected operation such as a preview deploy, including every repeat, the guard verifies the signed delivery permission's signature, increment, permitted action and expiry, and the freshly computed spec hash, and reads the policy from the hash-verified spec. Verification latency is an acceptance test; no timeout is fixed before it is measured. An agent-writable state file is never sufficient authority, and any verification failure fails closed (amended 2026-10-13).
- **Five escalation triggers** are the only reasons to interrupt the owner after authorisation:
  1. intent or scope;
  2. an owner-level trade-off, new dependency or new external service;
  3. accepting risk;
  4. a reserved operation, including a protected operation whose delivery permission is absent, expired or out of scope;
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
State that only explicit owner commands can change makes the boundary between intent and implementation checkable and measurable. (Amended 2026-10-13: "only explicit owner commands" is the supported interface, not a guarantee against direct edits; authority rests on signed owner approvals.) Routine work then needs no permission. Putting delivery policy in the approved spec moves one decision up front instead of asking many questions mid-delivery.

Signatures replaced tokens (2026-10-13) because only something outside the agent's software reach can attest a human. Evidence from the B-SE proof of concept in the Claude-running account (macOS 15.7.3, OpenSSH_9.9p2, Secretive 4.0.0 per the Homebrew cask listing):
- A1 PASS; A2 retry PASS (agent attempt refused); A3 PASS (unattended, no signature); A5 PASS (locked screen, no signature).
- The A2 first run is INCONCLUSIVE: the owner accidentally authenticated the agent's prompt, which is itself evidence for G1.
- A4a: Accessibility not granted, and the System Events query was blocked without completion; when it was denied is unknown. A4b (click and keystroke probes) was NOT EXECUTED, so the UI-automation boundary is unproven.
## Alternatives considered
### A pre-authorisation write-blocking hook
Not adopted initially (owner decision). Boundary crossings are measured instead. A blocking hook is reconsidered only if crossings occur.
### An extra confirmation prompt at `/deliver`
Rejected. The delivery policy is already in the approved spec, so `/deliver` shows it but doesn't ask again.
### Requiring a specific model for the coordinator
Rejected (owner decision D3). The coordinator is the main session, whose model the user chooses. Model routing stays in agent frontmatter, and Opus remains required where the risk policy calls for the Opus security reviewer.
### Authority tokens minted from `UserPromptExpansion` (originally adopted as D1)
Rejected 2026-10-13. A spike on Claude Code 2.1.296 showed the event fires for any session whose input starts with the slash command, including a nested `claude -p` and an interactive session driven through a pseudo-terminal by an agent with Bash. The latter produced hook markers identical to a human-typed command. The event may still create a pending request; it never grants authority.
### Tamper-evident tokens with a guard rule
Acceptable only as defence in depth, not as authority: an agent with Bash can evade guard rules.
### Other signing and separation options
- A FIDO2 hardware security key: equivalent verification and the same blind-signing gap; kept as an alternative.
- A root-owned terminal signer in the Claude account (G1-a): binds and presents the record but cannot prove the owner started the prompt.
- A dedicated GUI approver app (G1-c): depends on macOS privacy state; untested.
- GitHub approval by a separate identity, or full OS-user separation for the agent: stronger, but they need identity or OS changes not yet in place; recorded as future hardening.
### A custom orchestration runtime, Agent Teams or MCP
Rejected. They are unnecessary given native subagents, worktrees, background commands and hooks ([ADR-0001](ADR-0001-claude-native-architecture.md)).
## Consequences
- The owner types explicit lifecycle commands instead of conversational approvals, and signs each approval through the trusted approval path.
- Owner set-up is needed: Secretive and an approval key, the trust anchor (sudo), and the approver account and signer if G1-b is adopted.
- **Revocation limitation (open security requirement):** early revocation of an unexpired, otherwise valid signed delivery permission is NOT cryptographically enforceable in the current design. Agent-writable state is not a revocation authority, and `revoke` does not invalidate a valid signature; a permission stays usable until it expires. Durable trusted revocation is an open security requirement.
- **Replay limitation (open security requirement):** nonce consumption recorded in agent-writable state is not rollback-resistant. After an agent restores pre-use state, an unexpired, previously valid transition signature can be replayed, which can undo a later owner pause or state-only revocation. It re-applies only a transition the owner signed and creates no new cryptographic authority. Short expiry is a mitigation only. Rollback-resistant consumed-nonce tracking (a trusted store outside the agent's reach is a candidate, unproven) is required before single use counts as enforced.
- **Open risk G1:** the Secretive dialog shows the key and an app name, not the record; app names are not provenance; prompts can outlive their requester. Until G1 is closed, approving a prompt the owner did not knowingly start can authorise an agent-chosen request (observed once, by accident, in the proof of concept).
- Further residual risks are listed in `WORK-002` (G2–G8), including that root can replace the anchor and that agents act under the owner's GitHub identity.
- Platform updates and key rotation require re-running the minting regression checklist.
- State files can still be forged by any process with shell access, but a forged state without a valid signature does not pass the transition script. Reserved operations still pass through the guard and the platform's own controls (branch protection, environment approvals).
- Superseded (2026-10-06 text, kept as history): "Tokens and state files can be forged by any process with shell access. They make authority tamper-evident and detect accidental drift; they don't defend against a deliberately adversarial agent."
- Existing v0.2 work items need an import step. v0.2 delivery authority is never imported as v0.3 authority.
