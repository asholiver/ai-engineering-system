# Work Specification
## Status
**Current status (2026-10-13):** approved in principle for design. The revised authority mechanism (signed owner approvals, Scope items 3 and 7) is **pending security review and G1 closure**. It replaces `UserPromptExpansion` tokens after the spike showed that agents can trigger the event (D1 superseded). G1 (trusted approval path) is OPEN. G1-b (separate macOS approver account) is the provisional architecture for investigation, not an approved implementation. The trust anchor (O3) is deferred. Implementation and delivery are not authorised.

Original status (history): Approved (by Ashley Oliver, 2026-10-06), in principle, with owner decisions D1–D6 incorporated as recorded in `WORK-001-planning.md`. Delivery is not authorised; it may start only after the gate-bootstrap PR (D5) is merged and the owner explicitly authorises it.
## Work ID
WORK-002: Work lifecycle and authority (v0.3 PR B)
## Objective
Move work authority out of conversation into explicit state that only lifecycle commands can change. Once the owner authorises delivery of an approved spec, routine implementation proceeds autonomously, with no "continue", "approve fix" or "approve work-branch push" prompts, while valid, correctly scoped authorisation exists. When a delivery permission has expired or is absent, protected operations (such as preview deploys) pause for fresh owner approval; uninterrupted delivery is not promised. Every legitimate interruption maps to one of five triggers, and intent never changes without the owner.

Decision record: [ADR-0004](../../../docs/decisions/ADR-0004-work-authority-and-lifecycle.md). Programme context: [WORK-001-planning.md](WORK-001-planning.md).
## Scope
Included:
1. **Work-item state.** `.agents/specs/active/WORK-NNN.state.json` (schema under Data), committed with the work. One transition script (`workstate.sh` or equivalent, bash + jq) is the only writer. Every transition validates the current status, the actor requirement and, for owner-only transitions, a valid owner approval (Scope item 3).
2. **Lifecycle:** `proposed → approved → authorised → delivering → (blocked ↔ delivering) → done → archived`, with `paused` reachable from `authorised`, `delivering` or `blocked`. Transitions and actors:

   | Transition | Actor | Requirement |
   | :- | :- | :- |
   | create / → proposed | coordinator in `/plan` | spec exists |
   | proposed → approved | owner | `approve` approval; records the spec content hash and commit |
   | approved → authorised → delivering | owner | `deliver` approval; spec hash still equals the approved hash; records the delivery policy from the spec (informational copy; see Scope item 6) |
   | delivering → blocked | coordinator | a decision record with a trigger class |
   | blocked → delivering | owner answer | see Decisions below |
   | accept or waive risk, defer a finding, lower a tier, revoke | owner | `approve` approval with that sub-action (`revoke` changes state only; it cannot invalidate an unexpired signed delivery permission, see Scope item 3) |
   | raise a tier, record a finding fixed or invalid (non-security), record gate or review evidence | coordinator | none |
   | pause | owner or coordinator | none (pausing is always safe) |
   | resume a paused item | owner | `deliver` approval; returns the item to the status it was paused from |
   | delivering → done | coordinator | every increment merged (observed through Git) |
   | any change to the spec content | anyone | status returns to `proposed`, and delivery stops at the next transition check |

3. **Owner approvals: signed, verified unattended** (amended 2026-10-13; replaces the original "Authority tokens: silent and non-blocking" design, which relied on `UserPromptExpansion` and is superseded with D1).
   - **Two kinds of signed owner approval**, each a signature by the owner's user-presence key (Secure Enclave, Secretive with "Require Authentication") over a canonical record:
     - **Transition approval:** single-use by design, but not yet rollback-resistant (see the replay limitation below). It authorises exactly one owner-only lifecycle transition (`approve` sub-actions; `deliver` authorise and resume). Record: `{schema, kind: "transition", repository, workId, action, subAction, incrementId?, specCommit, specSha256, nonce, createdAt, expiresAt}`. The nonce is recorded as consumed on use.
     - **Delivery permission:** bounded and potentially reusable until it expires. It authorises a narrowly scoped protected operation during delivery (initially: ephemeral preview deploys, or one named persistent environment's exact command). Record: `{schema, kind: "deliveryPermission", repository, workId, incrementId, permittedActions, specCommit, specSha256, createdAt, expiresAt}`, where `permittedActions` names each operation exactly (for example `ephemeral-deploy`, or a persistent environment's name and the SHA-256 of its exact command).
     - **Replay limitation (open security requirement):** nonce consumption recorded in agent-writable state is NOT rollback-resistant. The current design cannot guarantee that a transition approval is used only once against an agent that restores the state from before it was used. After such a rollback, an unexpired, previously valid transition signature can be replayed, which can undo a later owner pause or state-only revocation (for example, by re-applying an earlier `deliver` or resume). Replay re-applies only a transition the owner actually signed, for the same record and spec hash; it does not create new cryptographic authority. A short transition-approval expiry is a mitigation only, not a replay-prevention guarantee; its duration is undecided.
     - **Revocation limitation (open security requirement):** early revocation of an unexpired, otherwise valid signed delivery permission is NOT cryptographically enforceable in the current design. Agent-writable state is not a revocation authority, and the `revoke` sub-action does not invalidate a valid signature. Until a durable trusted revocation mechanism exists, a permission stays usable until it expires.
     - **Initial design: short-lived and narrowly scoped.** Delivery permissions name one increment and an explicit action list, and expire quickly (lifetime to be chosen; see Open decisions). Longer-lived permissions and durable revocation are open questions. Security never depends on agent-writable revocation state: until durable revocation is designed, expiry is the only bound on a permission's lifetime.
     - Signed files may be stored in agent-writable locations, because tampering with or deleting them can only remove authority, never add it.
   - **Exact-byte binding.** The trusted owner signer (item 3b) derives the record itself, shows it to the owner and signs exactly those bytes. It never signs bytes supplied by an agent. It reads Git objects with repository configuration, pagers, hooks and textconv disabled, and treats repository content as untrusted data.
   - **Verification** is unattended: `ssh-keygen -Y verify` against the trust anchor (item 3a).
     - The transition script accepts a transition approval only for the single pending request it created (matching nonce), before `expiresAt`, once according to the consumed-nonce record (subject to the replay limitation), and when the spec hash it computes freshly equals `specSha256` and every other record field matches the request.
     - Each use of a delivery permission is verified afresh at the protected operation (Scope item 7): signature, kind, repository, work id, increment, the exact permitted action, `expiresAt` and a freshly computed spec hash. A previous successful verification never stands in for the next one.
   - **Namespaces.** `approve` and `deliver` use separate signature namespaces (`ai-engineering-approve`, `ai-engineering-deliver`) as well as the `action` field, so neither can stand in for the other. The `kind` field keeps a transition approval and a delivery permission from standing in for each other; whether delivery permissions also get their own namespace is open.
   - **Agent-writable state never expands authority.** State may only narrow what a verified signature allows.
   - **Fail closed.** A missing or untrusted anchor, an unverifiable signature or any mismatch refuses the transition with an explanation. There is never a fallback to conversation.
   - `UserPromptExpansion` may at most create a pending request as a convenience. It never grants authority (D1 superseded).
3a. **Trust anchor (O3, deferred).** An `allowed_signers` file pinning the owner's approval public key and its permitted namespaces.
    - **Provisional preference (2026-10-13):** a root-owned verification anchor in the Claude-running account, candidate `/Library/Application Support/ai-engineering/allowed_signers`, installed once by the owner with sudo. The private signing key stays isolated in the separate approver account (G1-b).
    - The verifier refuses unless every path component is root-owned, not group- or other-writable, and not a symlink.
    - Installation waits until the architecture and signing key are settled (under G1-b the key would be a new key in the approver account).
3b. **Trusted owner signer and approval path (G1, OPEN).** The owner must be able to review the exact request through a path the agent cannot modify, spoof or drive, and must be able to tell owner-initiated prompts from agent-initiated ones. Provisional architecture: **G1-b**, a separate macOS approver account (see Open decisions). Account separation alone is not treated as proof of security; G1 stays open until the G1-b proof of concept (Testing) passes and the owner separately approves closing G1.
4. **One new human-only command:** `/ai-engineering:approve <WORK-ID> [spec | accept <finding-id> | defer <finding-id> | tier <increment-id> <0|1|2> | revoke]` with `disable-model-invocation: true` (D2). `/ai-engineering:deliver <WORK-ID>` authorises, or resumes a paused item. A scope extension means amending the spec, then `approve`, then `deliver`.
   - `accept` records acceptance or waiver of a finding's risk. `defer` records an owner decision to defer a finding to later work. Each `approve` sub-action corresponds to exactly one of the owner-only transitions assigned to `approve` in the table in Scope item 2: approving a spec, accepting or waiving risk, deferring a finding, lowering a tier and revoking. Each of those transitions has a sub-action.
   - `/ai-engineering:deliver` performs the owner-only delivery transitions in that table: `approved → authorised → delivering`, and resuming a paused item. These transitions have no `approve` sub-action.
   - The commands create a **pending request** (nonce, expiry) through the transition script and print what the owner must sign through the trusted signer. They grant nothing themselves (amended 2026-10-13).
   - **Approval and delivery authorisation stay distinct.** An `approve` approval can never authorise or resume delivery. A `deliver` approval can never approve a spec, accept or waive risk, defer a finding, lower a tier or revoke. `deliver` on an item that isn't `approved` (or `paused`) is refused.
5. **`/plan` changes.**
   - New spec template: intent only, plus three new sections:
     - Increments, with the proposed tier and reasons for each;
     - Delivery policy;
     - Owner actions.
   - The template drops "Implementation state" and "Review state".
   - `/plan` creates or updates the state in `proposed`, commits nothing on its own, and ends by telling the owner to type `/ai-engineering:approve <WORK-ID>`.
   - Conversational approval never changes status.
6. **Delivery policy**, declared in the spec and copied into state at authorisation. The copy in state is informational only: the guard enforces policy derived from the hash-verified spec and the signed delivery permission, never from agent-writable state (Scope item 7). Fields:
   - `pushWorkBranch` (default true);
   - `openPullRequest` (default true; draft or ready per policy; never merge);
   - `ephemeralDeploy`: the increment ids where preview deployment may run autonomously, provided the required accounts and credentials already exist;
   - `persistentEnvironments`: optional `{name, exactCommand}` entries the owner pre-authorised.

   Production deployment can never be expressed in policy: validation rejects it, and the guard's `production-deploy` class always asks.
7. **Guard integration for delivery policy.** This is the only guard change in this spec. It is an isolated commit with its own security review, built on WORK-001's classes.
   - **Delivery authority is bound to a signed delivery permission, not to a status value or any agent-writable file** (amended 2026-10-13). An agent-writable state file is never sufficient authority. At every deploy decision, including every repeat of the same deploy, the guard verifies afresh:
     - a signed delivery permission (Scope item 3), against the trust anchor and in its namespace, whose `kind`, repository and work id match;
     - that the permission names the exact action being attempted (`ephemeral-deploy`, or the persistent environment and the SHA-256 of its exact command) and the increment it applies to;
     - that `expiresAt` has not passed;
     - that the SHA-256 of the spec file's current content, computed by the guard itself, equals the permission's `specSha256` (it never trusts a stored hash);
     - that the delivery policy read from that hash-verified spec still lists the action for that increment (never read from state).
     - Verification uses a fixed absolute verifier path. Its latency is an explicit acceptance test; no timeout value is set before it is measured. Any limit chosen from the measurement must fail closed. Any failure, missing anchor, missing permission, expiry or mismatch grants nothing and the command asks. This holds even if the state says `delivering`.
   - **`ephemeral-deploy`:** produces no decision when all of these hold:
     - a delivery permission for `ephemeral-deploy` verifies as above;
     - the command is alone (a context prefix is allowed);
     - exactly one work item in the repository is `delivering`, and its active increment equals the permission's `incrementId`.

     Otherwise it asks. State fields (status, active increment) only narrow what the signed permission allows; they never widen it.
   - **`persistentEnvironments`:** produces no decision only on an exact match of the `exactCommand` whose hash the verified permission names, run alone.
   - **Denial reasons, compatible with WORK-001:** a failed check keeps WORK-001's existing hook output (an `ask` decision with `permissionDecisionReason`) and its guard-log entry; no new exit codes or decision values are introduced. The reason text and log entry name one specific cause: permission missing, permission expired, wrong increment, wrong action, invalid signature (wrong key, namespace, kind or bytes), spec hash mismatch, or untrusted or missing anchor. Reason strings follow the guard's existing quoting constraints.
   - **Issuing permissions:** the owner signs delivery permissions through the same trusted approval path, for one increment at a time, when that increment's policy lists a protected operation. When a permission expires, the next protected operation asks, and the owner may sign a new one. When permissions are issued in the flow (with `deliver`, or at the start of each increment) is open.
   - Anything else in a deploy class still asks.
   - Original text (2026-10-06, superseded): the guard compared the fresh spec hash with `approval.specSha256` and `delivery.specSha256` read from state, and relied on state having been "written by the transition script, not edited by a tool".
8. **`/deliver` rewrite.**
   - Preconditions read state, not prose.
   - It prints a display-only delivery summary (scope, increments, tiers, policy, planned owner actions) without asking a confirmation question.
   - It plans tasks as a dependency graph by file area.
   - It runs independent tasks in parallel worktrees by default.
   - It runs the fast gate after each task.
   - It remediates inside intent.
   - At the end of each increment it runs the review procedure (single home: the `review` skill; WORK-003 makes that the readiness procedure).
   - It pushes the work branch and opens or updates the increment PR per policy.
   - It waits for the owner's merge in the background, then continues with the next increment without a prompt.
9. **Coordinator-owned Git.**
   - The coordinator creates the work branch, commits, merges worktree branches, pushes and opens PRs.
   - Specialists edit and test only (enforced by WORK-001's guard policy; instructions updated here).
   - Merge conflicts between worktrees are resolved by the coordinator. If resolving one would require a decision about intent, that is trigger 1.
10. **Escalation triggers.** The only reasons to block and interrupt the owner after authorisation:
    1. intent or scope change;
    2. an owner-level trade-off: security, product, UX, performance or cost compromise, new dependency, or new external service, account or credential;
    3. accepting, waiving, deferring or downgrading risk, or disputing a security finding;
    4. a reserved operation, including a protected operation whose delivery permission is absent, expired or out of scope (amended 2026-10-13);
    5. an ambiguity whose readings build different things.

    Specialists report open questions tagged with a proposed trigger. The coordinator resolves anything that is not a trigger itself and records the reasoning in the log.
11. **Remediation policy.**
    - Findings inside intent are fixed autonomously at any severity and recorded as `fixed(<sha>)`.
    - Fixes of HIGH or above are listed in the readiness report.
    - Non-security findings may be recorded `invalid` with evidence by the coordinator. Security findings need the raising reviewer's confirmation, otherwise trigger 3.
    - Weakening a test, gate or control to clear a finding is trigger 3.
12. **Decisions.**
    - Answers that choose among options inside approved intent (triggers 1, 2 and 5, when no scope is added) may be given in conversation. The coordinator records them verbatim with `source: conversation`, and the readiness report lists them.
    - Answers that grant authority need the `approve` command: accepting risk, lowering a tier, adding scope.
13. **Spec/log split and lean context.**
    - `WORK-NNN.log.md` is append-only, written only by the coordinator, and never sent to specialists.
    - Specialist handoffs contain the task, its acceptance criteria, the files in scope and the relevant spec sections, with a pointer to the full spec. For legacy v0.2 specs, the "Implementation state" and "Review state" sections are excluded from excerpts.
14. **Bounded recovery and waits.**
    - A stalled or failed specialist is re-dispatched once automatically with a fresh brief; a second failure escalates. Recoveries are recorded in state.
    - Provider errors are left to the harness's retries; resuming means reading state.
    - External waits (CI checks, owner merge) run as bounded background commands through a helper script around authenticated `gh`. It validates responses, backs off, has a timeout, and reports `NOT AUTHENTICATED` as a planned owner action. It never polls unauthenticated, and never treats an error payload as data.
15. **Learnings:** collected during the increment and written once at its end, not one learning-agent spawn per append. `/learn` is unchanged.
16. **Removals:**
    - the "Prove" duplication in `deliver`;
    - playbook selection in `deliver` (playbooks stay available to `/plan`);
    - the setup worktree question;
    - "Any open decision goes to the user".
17. **`/setup` changes.**
    - Writes `"worktree": {"baseRef": "head"}` by default, explaining the effect on the user's own `claude --worktree` sessions and the documented opt-out.
    - Gains an **import** mode for v0.2 work items (see Migration).
    - Gains a session banner line from `inject-standards.sh` with the plugin version and plugin root path, so the active plugin source can be proven during testing and after upgrades.
18. **Metrics capture in state** (WORK-003 reports them):
    - approval, authorisation, increment active/ready/merged and done timestamps;
    - each decision's trigger and its asked/answered times;
    - each owner action's requested/done times;
    - recovery count.

Excluded (non-goals):
- Risk classification, gate trust, the review ledger and readiness rules (WORK-003).
- Parser or classification changes (WORK-001).
- A blocking pre-authorisation write hook.
- Agent Teams, MCP, new agents, a custom runtime.
- Any requirement on the main session's model (D3). The user chooses it. Model routing stays in agent frontmatter, and Opus remains required where the risk policy calls for the Opus security reviewer.
- Non-GitHub wait helpers.
- Modifying Landra.
## Requirements
- Scripts are bash + jq, and every behaviour change has a case in `tests/run.sh`.
- Always-loaded context stays within `scripts/check.sh` budgets. New commands use `disable-model-invocation: true`.
- State writes are atomic (write then rename) and validated against the schema before replacing the file. A corrupt or unreadable state file stops delivery with a clear message; the script never repairs it silently.
- Owner-only transitions are impossible without a valid owner signature. This is tested by calling the script directly.
- Signing and verification use OpenSSH `ssh-keygen -Y sign` and `-Y verify`. Proof-of-concept environment: macOS 15.7.3, OpenSSH_9.9p2 with LibreSSL 3.3.6 (`/usr/bin/ssh-keygen`); Secretive 4.0.0 according to the Homebrew cask listing before installation (the installed build was not read).
- Owner actions are declared up front: Secretive and key set-up (a new key if G1-b is adopted), the approver account (G1-b), the trusted signer, and the trust anchor (O3).
- After a Secretive, macOS or OpenSSH update, or a key rotation, the minting regression checklist (A2, A3, A5 equivalents) is re-run before signatures are trusted again.
## Business rules
- Conversation never grants authority.
- A spec change invalidates approval.
- v0.2 authority is never imported as v0.3 authority.
- Risk is never accepted or waived silently.
- Production deployment, merge, release, publish, default-branch push, destructive operations, and creating or changing accounts, credentials or consequential external resources always need the owner.
## Architecture
Affected areas:
- `plugins/ai-engineering/scripts/`:
  - new transition script;
  - signature verification inside the transition script (amended 2026-10-13; replaces the token hook script);
  - the trusted owner signer (form and location depend on G1);
  - new wait helper;
  - `inject-standards.sh` (banner);
  - `guard-bash.sh` (policy integration, plus the defence-in-depth rules in Security).
- `hooks/hooks.json` (no UserPromptExpansion entry is required; amended 2026-10-13).
- `skills/plan`, `skills/deliver`, `skills/review` (deliver calls it; content changes belong to WORK-003), `skills/setup` (+ templates), and a new `skills/approve`.
- `agents/{frontend,backend,platform}.md` (handoff and decision-reporting wording).
- `docs/`, `tests/run.sh`, `scripts/check.sh` (only if new budgets or checks are needed).

Exact script names and the internal schema layout are left to the implementer. The canonical approval record format is fixed in the spec before implementation, because the trusted signer and the verifier must agree on its exact bytes.
## Data
Conceptual state:
```
{ schemaVersion, id, title, status,
  spec:      { path, contentSha256, approvedCommit },
  approval:  { by, at, specSha256, source: "signature" | "imported", importedFrom? } | null,
  delivery:  { by, at, specSha256, policy } | null,
  ownerActions[]: { id, description, increment, status, requestedAt, doneAt },
  decisions[]:    { id, trigger, question, options, askedAt, answeredAt, answer, source: "signature" | "conversation", by },
  increments[]:   { id, title, status: planned|active|ready|merged, proposedTier, branch, pr,
                    baseSha, headSha, mergeSha, recoveries },
  findings[]:     { id, source, severity, summary, disposition: open | fixed(sha) | invalid(evidence, confirmedBy) | owner(decisionId) },
  permissions[]:  { incrementId, permittedActions, expiresAt, signaturePath },   // a record only; the guard verifies the signed file, never this entry
  history[]:      { at, transition, actor, approvalId? } }
```
WORK-003 adds tier, gate and review-ledger fields to `increments[]`.
## API
- Transition script: subcommands for each transition, plus request creation. Exit codes distinguish success, invalid transition, missing, invalid, expired or reused approval, untrusted anchor, schema error and spec-hash mismatch; within the approval exit code, a one-line message names the specific cause (expired, wrong increment, wrong action, invalid signature, nonce not pending or reused). The exact numbering is left to the implementer.
- Guard: no new interface; denial reasons are carried in WORK-001's existing `ask` output and guard log (Scope item 7).
- Wait helper: `checks <pr|sha>` and `merge <pr>` modes with a timeout; prints one verdict line.
## UI
- The owner types `/ai-engineering:approve` and `/ai-engineering:deliver`, then reviews and signs the request through the trusted approval path (one deliberate review and one Touch ID or password confirmation per transition approval or delivery permission). A new increment, a new action scope or an expired permission can require another approval.
- The delivery summary is printed, not asked.
- Escalations state their trigger class, the options and a recommendation.
## Security
- **Threat model (amended 2026-10-13):** an agent with unrestricted Bash, running as the owner's macOS user in the Claude-running account.
- **Withdrawn claim:** the original design said "the model can't trigger the expansion event". The 2026-10-13 spike on Claude Code 2.1.296 falsified it: a nested `claude -p` and an interactive session driven through a pseudo-terminal both fired `UserPromptExpansion`, the latter with markers identical to a human-typed command.
- **Authority forgery:**
  - tool writes to state are denied (WORK-001);
  - an owner approval needs a user-presence signature that the agent cannot produce on its own;
  - transition approvals are bound to the exact record and intended to be single-use and short-lived; single use is not rollback-resistant in the current design (replay limitation); delivery permissions are short-lived, bound to one increment and an explicit action list, and verified afresh on every use (Scope items 3 and 7);
  - revocation state written by agents is never relied on; expiry bounds every permission.
  - **Replay limitation (open security requirement):** nonce consumption recorded in agent-writable state is NOT rollback-resistant. The current design cannot guarantee that a transition approval is used only once against an agent that restores the state from before it was used. After such a rollback, an unexpired, previously valid transition signature can be replayed, which can undo a later owner pause or state-only revocation (for example, by re-applying an earlier `deliver` or resume). Replay re-applies only a transition the owner actually signed, for the same record and spec hash; it does not create new cryptographic authority. A short transition-approval expiry is a mitigation only, not a replay-prevention guarantee; its duration is undecided.
  - **Revocation limitation (open security requirement):** early revocation of an unexpired, otherwise valid signed delivery permission is NOT cryptographically enforceable in the current design. Agent-writable state is not a revocation authority, and the `revoke` sub-action does not invalidate a valid signature. Until a durable trusted revocation mechanism exists, a permission stays usable until it expires.
- **B-SE proof-of-concept evidence (2026-10-13; Claude-running account, no separate approver account)**, outcomes as observed:
  - A1 PASS: the owner's signature verified; a wrong namespace and a one-byte change were rejected.
  - A2 first run INCONCLUSIVE: the owner accidentally authenticated the agent's prompt, and the agent's signature verified.
  - A2 retry PASS: each of two owner signatures needed a fresh prompt; the agent attempt one second later was refused ("agent refused operation", exit 255, no signature).
  - A3 PASS: an unattended attempt blocked for 75 s and was killed; no signature. Its prompt lingered until the owner denied it.
  - A4a: `AXIsProcessTrusted()` returned false. The System Events query was blocked without completion for 60 s (exit 137). The owner saw "iTerm wants access to control System Events"; when it was denied is unknown.
  - A4b (click and keystroke probes): NOT EXECUTED.
  - A5 PASS: the screen was locked; the attempt blocked for 75 s and was killed; no signature. After unlock a Secretive prompt for it was waiting, and the owner denied it.
  - A6: the fallbacks offered were Touch ID or the account password, both human-only.
- **Defence in depth, not the authority boundary (proposed; not settled, scope to be confirmed, see Open decisions):** the guard would ask (coordinator) or deny (specialists) on Bash commands that launch nested Claude Code sessions, use the Secretive agent socket, run `ssh-keygen -Y sign` or invoke the owner signer. Such rules can be evaded through Bash and are never relied on for authority.
- **Residual risks (documented):**
  - **G1 (OPEN):**
    - the Secretive dialog shows the key and a requesting app, not the record (blind signing);
    - app attribution is not provenance, because an agent can launch apps (reasoned, not tested);
    - prompts outlive their requester (A3, A5);
    - an accidental approval was observed (A2 first run).
  - **G2:** the anchor is not established; anchor tests P1, P2, P5 and P6 are untested.
  - **G3:** nonce, expiry and replay protection are design only, and consumed-nonce tracking in agent-writable state is not rollback-resistant (replay limitation).
  - **G4:** the verifier cannot prove the key is Secure Enclave–backed with Require Authentication.
  - **G5:** the UI-automation boundary depends on macOS privacy state (Accessibility, Automation); A4b was not executed.
    - Unexplained observation (2026-10-13): during the proof-of-concept session the owner saw a macOS prompt "iTerm would like access to data from other apps". Its cause is unexplained. It was not reproduced, and no privacy permission was changed to investigate it.
  - **G6:** platform drift (Secretive, macOS, OpenSSH).
  - **G7:** key rotation and availability (rotation needs sudo for a root-owned anchor).
  - **G8:** root can replace the anchor; agents act under the owner's GitHub identity.
  - State and log files remain forgeable by a process with shell access outside tool hooks. Forged state cannot create authority without a valid signature: the transition script and the guard both verify the signed owner approval at the protected operation (Scope items 3 and 7). It can, however, undo a state-only revocation, for example by returning a revoked item to `delivering`, while a signed delivery permission is unexpired (see the revocation limitation). Restoring pre-use state can also re-enable replay of an unexpired transition approval (see the replay limitation). It can also mislead reports or deny service. Reserved operations remain guarded, and branch protection and environment approvals remain the hard controls.
- **Prompt injection** from issues, dependencies or tool output can create at most a pending request, never an approval. Agents treat tool output as data.
- **Preview deployment:**
  - allowed only for ephemeral deploys of the active, authorised increment, using existing credentials;
  - never production;
  - never inside a compound command;
  - never when the state is ambiguous (zero or several items delivering).
- **Wait helper:** authenticated `gh` only; responses validated; never logs tokens.
## Scalability and reliability
- Bounded retries, timeouts and backoff for waits.
- One automatic recovery per stalled task.
- Atomic state writes.
- Several work items may exist, but the guard's deploy allowance requires exactly one in `delivering`.
## Observability
- State timestamps and `history[]` support these metrics: authorisation-to-readiness time, owner-wait proportion, interruptions by trigger, planned owner actions measured separately, and recoveries.
- `log.md` holds the narrative.
## Testing
Deterministic cases in `tests/run.sh`:
- **Transition table:** every allowed transition succeeds with the right actor and approval; every disallowed transition fails with the specific exit code.
- **Owner approvals** (amended 2026-10-13), with throwaway software keys and a test anchor:
  - a valid signature over the pending request is accepted, and a second use against the current consumed-nonce record is refused;
  - refused: wrong key; wrong namespace; an `approve` signature used for `deliver` and the reverse; wrong work id or sub-action;
  - **request substitution:** a signature over a different record, a changed byte, a pending request edited after signing, or a spec changed between signing and verification is refused;
  - **replay:** a reused nonce, a nonce not pending, a signature from another repository or work item, and an expired request are refused;
  - **rollback replay (planned adversarial test):** consume a transition approval, restore the state from before it was used, then retry the same unexpired signature. With the current provisional design (consumed nonces in agent-writable state) the replay is expected to succeed: this is recorded as an **expected security failure**, not an acceptable pass. The final design must reject the replay;
  - **anchor:** missing, user-owned, group- or other-writable, or reached through a symlink is refused;
  - every `approve` sub-action (`spec`, `accept`, `defer`, `tier`, `revoke`) maps to its owner-only transition, and `defer` without an approval is refused;
  - an owner-only transition without an approval is refused, and no refusal changes state.
- **Intent/implementation boundary:**
  - (a) A prompt "we also need to update the README" creates no approval. A `proposed` item stays `proposed`, and `deliver` preconditions refuse it.
  - (b) During `delivering`, a spec edit adding a README requirement changes the spec hash, and the next transition returns the item to `proposed` and stops delivery.
- **Policy validation:** a spec policy containing a production deploy, or `persistentEnvironments` without an exact command, is rejected at approval.
- **Guard and policy:** with fixtures for state and policy:
  - `vercel deploy` → none when delivering and the increment is listed;
  - → ask when the item is `authorised` but not `delivering`, when the increment isn't listed, when two items are delivering, or when the command is compound with another effectful command;
  - `vercel --prod` → always ask;
  - with the item still `delivering` and the increment listed, but the spec file edited (committed or not) since approval → `vercel deploy` asks, and a persistent exact match asks. The state is left untouched, proving the check happens at the deploy decision itself;
  - a missing or unreadable spec file → ask;
  - a persistent exact match → none; a near-miss → ask;
  - **forged state** (amended 2026-10-13): state saying `delivering` with the increment listed, but no delivery permission, a signature by the wrong key or namespace, a transition approval presented as a permission, a permission over a different spec hash, an expired permission, a policy edited into state but absent from the hash-verified spec, or a missing or untrusted anchor → `vercel deploy` and persistent matches ask;
  - **scope binding:** a permission for increment A used while state says increment B is active → ask; state edited to make B active, or to list B in the policy → ask; a permission for `ephemeral-deploy` used for a persistent environment, or for one persistent command used for another → ask;
  - **repeat use:** a deploy that succeeded is repeated after the permission expires, or after the spec changes → ask; a repeat within scope and expiry is verified again, not served from an earlier result;
  - **denial reasons:** each failure above produces an `ask` whose reason and guard-log entry name the specific cause (expired, wrong increment, wrong action, invalid signature, spec hash mismatch, anchor), and existing WORK-001 guard cases are unchanged;
  - **revocation limitation:** after `revoke` changes state, a forged return of state to `delivering` with an unexpired valid permission is documented as still verifying (a known limitation, recorded rather than hidden); the item's honest state asks;
  - **verification latency:** measured at deploy decisions on the target machine and recorded as an acceptance test; a timeout is chosen only from that measurement, and a verifier that exceeds it fails closed.
- **Import:** v0.2 spec fixtures (Draft, Approved, legacy state sections, Approved with a partially delivered history):
  - the resulting state is never `authorised` or `delivering`;
  - approval `source: imported` with the approver and date taken from the Status line;
  - legacy sections untouched;
  - the import is idempotent.
- **Wait helper** with a fake `gh` on `PATH`: success, failure, timeout, unauthenticated, rate-limit error payload and malformed JSON each produce the correct verdict. No unauthenticated network call is ever made.
- **Setup:** the template contains `worktree.baseRef: "head"`. The banner prints the version and root, within budget.

**G1-b proof of concept** (owner-run; required before G1 can close and before O3). Each test records the exact command, outcome and macOS state:
- **Cross-account access:** from the Claude-running account, the approver account's Secretive agent socket, key container, keychain items, signer files and approval interface are unreachable (open, connect, read, list and launch attempts all fail). Processes in the approver session cannot be launched or driven from the Claude account.
- **Approval provenance:** a prompt in the approver session appears only after an owner action there; an agent action in the Claude account produces no prompt there.
- **Trusted presentation and request substitution:** the signer shows the record it derived; an agent changing the pending request, the spec or the repository's Git configuration between display and signing produces either a refused signature or a visible difference, never a signature over unseen bytes.
- **Replay:** a captured transition approval cannot be reused for another nonce, work item, action or repository, and a captured delivery permission cannot be used for another increment, action or repository, or after it expires.
- **Stale prompts:** a prompt that outlives its request (owner away, screen locked, request expired) cannot authorise anything; an approval of an expired or consumed request is refused (for consumed requests, only once rollback-resistant tracking exists; see the replay limitation).
- **Minting regression:** A2, A3 and A5 equivalents in the approver account.
- **Request transfer and signature return** (design in Open decisions, G1-b):
  - a pending request edited or swapped by the agent after the owner starts review does not result in a signature over bytes the owner did not see;
  - a signature or file planted on the return path by the Claude account is refused by the verifier, or never read by the approver account;
  - an oversized, malformed or symlinked request or snapshot is refused by the signer within its limits;
  - terminal control sequences or look-alike characters in the spec, request or commit message are neutralised or flagged in the signer's display.

End-to-end scenarios run deliberately in a scratch project, using unreleased source per the self-development protocol in `WORK-001-planning.md`. Evidence goes in `WORK-002.log.md`.
- **E1.** Plan → approve → deliver a two-task spec with a planted failing test and a planted in-intent QA finding. Expected:
  - no continue, fix or push prompts;
  - work branch pushed to a local bare remote;
  - both remediations recorded;
  - readiness reached.
- **E2.** A mid-delivery conversational "we also need to update the README". Expected: recorded as a trigger-1 scope proposal, the README untouched, delivery continues on the approved scope.
- **E3.** A stalled specialist (simulated with a deliberately hanging task) is resumed once, then escalated.
## Risks
- **UserPromptExpansion behaviour:** resolved 2026-10-13. It cannot attest a human and is no longer part of the authority mechanism.
- **Approval path (G1):** may not reach an acceptable design; if G1-b fails its proof of concept, the owner decides between the remaining options before implementation.
- **Owner friction:** one deliberate review and one authentication per transition approval or delivery permission, plus a user switch under G1-b. A new increment, a new action scope or an expired permission can require another approval.
- **Parallel worktrees** need dependencies installed (`.worktreeinclude`). Document; fall back to sequential when installation fails, recording why.
- **Background merge waits across long gaps.** Bounded; an expired wait records "waiting for owner merge" as a planned owner action, not an interruption.
## Acceptance criteria
1. Only the transition script changes state, and every owner-only transition requires a valid owner signature.
2. `/ai-engineering:approve` and `/ai-engineering:deliver` create pending requests without guard noise. Each transition approval and each delivery permission costs the owner one deliberate review and one authentication through the trusted approval path. A new increment, a new action scope or an expired permission can require another approval (amended 2026-10-13; the original criterion was silent token minting).
3. A conversational statement never changes status or grants delivery authority (boundary tests pass).
4. After `/deliver`, routine fixes, work-branch pushes and PR updates proceed without owner prompts (E1).
5. Interruptions occur only for the five triggers, each recorded with its trigger class.
6. HIGH-or-above fixes appear in the readiness report. No risk is accepted or waived without a signed owner approval.
7. A spec change returns the item to `proposed`.
8. Specialists never perform Git writes. The coordinator owns branches, commits, merges, pushes and PRs.
9. Parallel worktrees are the default, and the opt-out is documented.
10. Specialist handoffs exclude the log and legacy state sections.
11. Stalls are recovered once automatically. External waits run in the background, authenticated, validated and bounded.
12. Ephemeral preview deployment runs autonomously only under the conditions in Scope item 7, including cryptographic verification of the signed owner approvals at the deploy decision and a freshly computed spec hash that matches the signed hash. State alone never grants deploy authority. A spec changed since approval never keeps deploy authority, whatever the recorded status. Production always asks.
13. v0.2 work items import without fabricated authority.
14. The session banner shows the active plugin version and root.
15. `scripts/check.sh` passes.
16. The G1-b proof of concept (or the owner-chosen alternative) passes, and the owner closes G1 before implementation of the approval path starts.
17. Guard verification latency at deploy decisions is measured and recorded, and any timeout derived from it fails closed.
18. The documentation states that early revocation of an unexpired signed delivery permission is not cryptographically enforceable in the current design, and no command, message or report claims that `revoke` invalidates a valid signature. Durable trusted revocation is tracked as an open security requirement.
19. Single-use enforcement of transition approvals is not considered satisfied until the final design passes the rollback replay test (Testing): consuming an approval, restoring pre-use state and retrying the same unexpired signature is rejected. Until then the documentation states the replay limitation.
## Definition of done
- Implementation complete; deterministic tests pass; E1–E3 evidence recorded
- `scripts/check.sh` passes
- Internal security review of the approval, signer, state and guard-policy changes (Opus) with no unresolved findings
- Independent external review passes
- Human acceptance complete
## Compatibility and migration
- **v0.2 projects:** existing specs keep working as documents. `deliver` refuses items without state and points to `/ai-engineering:setup` import.
- **`gates.json`:** unchanged by this spec.
- **Import:**
  - creates state per item from the spec Status line and Git history;
  - optionally records merged historical increments (PR, merge SHA) after the owner confirms them during setup;
  - never sets `authorised` or `delivering`, and never rewrites legacy spec sections.

  Historical review evidence is imported by WORK-003.
- **Landra WORK-001** (later, not now):
  - import gives `approved (imported)` with F0-S0/S1 recorded as merged (PR #1);
  - F0-S2 (preview, tier 2) and F0-S3 (production, tier 2) are added by a `/plan` amendment, which returns the item to `proposed`;
  - the owner then approves and delivers;
  - F0-S2's account, credential and resource steps are declared up front as owner actions, and preview deployment runs autonomously after them;
  - F0-S3 production deployment remains owner-run.
- **Upgrading:** the documented procedure must check the session banner, because an existing user-level marketplace registration can keep an older release active.
## Documentation
- `README.md`: commands (add `approve`), lifecycle, what runs without prompts.
- `docs/architecture.md`: state and authority, lifecycle, triggers, Git ownership, concurrency default, waits and recovery, delivery policy.
- `docs/consuming-project.md`: import, worktree default and opt-out, `gh` authentication requirement, upgrade verification through the banner.
- `docs/model-policy.md`: retry and recovery wording.
- `versions/CHANGELOG.md`.
## Independent review
- **Internal review.** Opus security review of the signature verification, trusted signer, transition script and guard-policy commit specifically.
- **External review.** CodeRabbit on the PR at its head SHA, with no unresolved actionable findings (D5 arrangement while v0.2.0 governs).
- **Gate scripts.** Under v0.2 the gate commands come from the base ref, but `tests/run.sh` and `scripts/check.sh` are executed from the change itself. Reviewers must check every diff to those two files, and a weakened or removed check is a blocking finding.
- **Owner acceptance.** The owner checks the transition table and the Business rules list.
## Dependencies
- Guard-policy integration (Scope item 7) needs WORK-001 merged, because it uses the deploy classes and authority-store protection. Everything else can proceed in parallel with WORK-001.
- WORK-003 builds on this state model.
## Settled owner decisions
- Work-branch pushes are autonomous once delivery is authorised.
- Remediation depends on fix versus accept, not severity.
- No pre-authorisation write hook.
- One PR per meaningful increment by default (not an invariant).
- Parallel worktrees by default with an opt-out.
- Coordinator-owned Git.
- Deployment authority as clarified on 2026-10-06 (preview autonomous under policy; persistent only if pre-authorised; production owner-only). **Amended 2026-10-13:** preview and pre-authorised persistent deploys run autonomously only while a valid signed delivery permission covers that increment and action; on expiry or absence they pause for fresh owner approval.
- The command-token mechanism. **Superseded 2026-10-13** by owner signatures (Scope item 3).
- D1: tokens come from `UserPromptExpansion`, never `UserPromptSubmit`. **Superseded 2026-10-13:** `UserPromptExpansion` fires for agent-launched sessions too, so it cannot attest the owner. It may only create pending requests.
- B-SE (user-presence owner signatures) selected as the baseline (2026-10-13), subject to G1 and O3.
- D2: the human-only `/ai-engineering:approve` command exists, and approval stays distinct from delivery authorisation.
- D3: no main-session model requirement.
- D5: the gate-bootstrap PR is merged before this work starts, and CodeRabbit is the external reviewer for this PR.
## Open decisions
- **G1, trusted approval path (OPEN).** The design must provide trusted request presentation, exact-byte binding, prompt provenance, protection against stale prompts, and protection against accidental approval of agent-initiated requests. A short confirmation code alone is not sufficient while an agent can control both the request and what is displayed. Options considered:
  - **G1-a:** a root-owned terminal signer in the Claude account. It gives binding and presentation but **not provenance**: an agent can run the signer or `ssh-keygen` through a pseudo-terminal, and the resulting prompt looks the same.
  - **G1-b (provisional, selected 2026-10-13 for investigation; not approved for implementation):** a separate macOS approver account holds Secretive, a new approval key and the trusted signer. The owner switches user to review and sign.
    - Intended property: the Claude-running account cannot reach that account's key, agent socket, signer or interface, so every prompt there follows an owner action.
    - Costs (accepted by the owner, 2026-10-13, as the price of deliberate review): a second account, a new key and Secretive set-up there, a user switch per approval, an independent repository copy in the approver account, and a signature return path.
    - **Repository view (owner preference):** an independent, read-only clone or trusted snapshot in the approver account, never the Claude account's working tree. The signer reads it with hooks, repository configuration, pagers, textconv, filters and submodules disabled, treats all content as untrusted, bounds sizes and refuses symlinks.
    - **Update source: undecided.** Both GitHub (the agent can push under the owner's identity, G8) and the Claude-running account are untrusted inputs. Whatever the source, the owner independently reviews the exact commit and the specification digest the signer will sign, from the approver account's own copy, before authenticating.
    - **Request transfer (Claude account → approver):** the approver signer takes only identifiers from the pending request and treats them as untrusted: for a transition approval, repository, work id, action, sub-action, nonce and spec commit; for a delivery permission, repository, work id, increment id, the requested permitted actions and spec commit. It derives everything else from its own snapshot, and checks that a requested permission's actions are listed for that increment in the snapshot's spec. It shows the derived record and the spec content before signing. Threats to design against: substituted or swapped requests, a commit changed between fetch and display, display injection (control sequences, look-alike characters), oversized input, and denial of service.
    - **Signature return (approver → Claude account):** the signature is written to a location the approver account owns and the Claude account can only read. The verifier treats anything found there as untrusted. A transition approval is accepted only if it verifies against the anchor for a pending nonce, before expiry, and has not been consumed; making that consumed-nonce check rollback-resistant is an open requirement (below). A delivery permission is accepted only when verified at each use (Scope item 7): signature, kind, repository, work id, increment, exact action, expiry and a fresh spec hash. The approver account never reads or executes anything the Claude account places on this path. Threats to design against: planted or replayed signatures, symlink or permission tricks on the drop location, and a stale signature for an expired request.
    - Nothing is created yet: no account, clone, permission or service.
    - Account separation alone is not proof of security. G1 stays open until the G1-b proof of concept in Testing passes and the owner separately approves closing G1.
  - **G1-c:** a dedicated GUI approver app in the Claude account. It depends on G5 (A4b not executed), and whether Secretive's app attribution can be spoofed is unknown. Untested.
  - **G1-d:** accept the residual with G1-a's mitigations only.
- **Rollback-resistant consumed-nonce tracking (open security requirement, under G1-b):** single-use transition approvals need consumed-nonce tracking that the agent cannot write or roll back. A trusted store outside the agent's write and rollback reach (for example, kept by the approver account) is a candidate, not an approved solution. Its atomicity, accessibility at verification time, persistence and rollback resistance require proof, and the rollback replay test must pass against it.
- **Delivery permissions:** the initial design is short-lived and narrowly scoped (Scope items 3 and 7). Still open:
  - the initial lifetime;
  - when permissions are issued in the flow;
  - whether they get their own signature namespace;
  - longer-lived permissions;
  - durable trusted revocation that does not depend on agent-writable state (an open security requirement, not an enhancement).
- **O3, trust anchor:** deferred. Provisional preference: a root-owned verification anchor in the Claude-running account, with the private signing key isolated in the approver account.
- **Approver repository update source:** undecided (see G1-b).
- **Guard rule scope:** confirm ask for the coordinator and deny for specialists on nested Claude launches and signer use (defence in depth only).

D2, D3 and D5 remain resolved (see `WORK-001-planning.md`); D1 is superseded.
## Implementation state
<!-- v0.2 deliver records task status and verdict lines here. Keep entries to one line each; put detailed evidence in WORK-002.log.md. -->
-
## Review state
<!-- v0.2 review records its status block here. -->
-
