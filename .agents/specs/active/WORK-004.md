# Work Specification
## Status
**Proposed (2026-10-16), not approved.** Created by the Path B split of WORK-002 (owner decision, 2026-10-16). It holds the signed-approval, replay, trust-anchor and autonomous-deployment content moved out of WORK-002, and replaces WORK-002's interim owner-command mechanism when it ships. G1 (trusted approval path) is OPEN, and the trust anchor (O3) is deferred. Design, implementation and delivery are not authorised. Not part of v0.3.0.

The moved text is unchanged from WORK-002 at `454f69f` unless marked "(2026-10-16)". In it, "Scope item 3" and "Scope item 7" refer to items 1 and 4 below, and owner-only transitions are those in WORK-002's transition table.
## Work ID
WORK-004: Signed owner approvals and autonomous deployment
## Objective
Replace WORK-002's interim owner-command transitions with signed owner approvals that an agent cannot produce, and let protected delivery operations (initially ephemeral preview deploys) run autonomously only while a valid, narrowly scoped signed delivery permission covers them. Single use must be rollback-resistant, and verification must rest on a trust anchor outside the agent's write reach.

Decision record: the proposed signed-approval amendment in [ADR-0004](../../../docs/decisions/ADR-0004-work-authority-and-lifecycle.md). Context: [WORK-002](WORK-002.md).
## Prerequisites (2026-10-16)
Implementation does not start until all of these hold:
1. The owner closes G1 (item 3 below), on the G1-b proof of concept in Testing or an owner-chosen alternative.
2. The owner accepts the signed-approval amendment to ADR-0004.
3. The canonical approval record format is fixed in this spec. The G1-B v0-test prototype format (fixed-order ASCII `key: value`, separate transition and delivery namespaces) is the starting point; its assumptions F1–F9 are reviewed, not adopted automatically.
4. The rollback-resistant replay store (item 5) is chosen.
5. WORK-002 is merged and released in v0.3.0.

Production activation (signatures granting real authority in a project) additionally needs the trust anchor installed (O3), the rollback replay test passing, verification latency measured, and the owner's decision on the admin-boundary residual risks.
## Scope
Included:
1. **Owner approvals: signed, verified unattended** (amended 2026-10-13; replaces the original "Authority tokens: silent and non-blocking" design, which relied on `UserPromptExpansion` and is superseded with D1).
   - **Two kinds of signed owner approval**, each a signature by the owner's user-presence key (Secure Enclave, Secretive with "Require Authentication") over a canonical record:
     - **Transition approval:** single-use by design, but not yet rollback-resistant (see the replay limitation below). It authorises exactly one owner-only lifecycle transition (`approve` sub-actions; `deliver` authorise and resume). Record: `{schema, kind: "transition", repository, workId, action, subAction, incrementId?, specCommit, specSha256, nonce, createdAt, expiresAt}`. The nonce is recorded as consumed on use.
     - **Delivery permission:** bounded and potentially reusable until it expires. It authorises a narrowly scoped protected operation during delivery (initially: ephemeral preview deploys, or one named persistent environment's exact command). Record: `{schema, kind: "deliveryPermission", repository, workId, incrementId, permittedActions, specCommit, specSha256, createdAt, expiresAt}`, where `permittedActions` names each operation exactly (for example `ephemeral-deploy`, or a persistent environment's name and the SHA-256 of its exact command).
     - **Replay limitation (open security requirement):** nonce consumption recorded in agent-writable state is NOT rollback-resistant. The current design cannot guarantee that a transition approval is used only once against an agent that restores the state from before it was used. After such a rollback, an unexpired, previously valid transition signature can be replayed, which can undo a later owner pause or state-only revocation (for example, by re-applying an earlier `deliver` or resume). Replay re-applies only a transition the owner actually signed, for the same record and spec hash; it does not create new cryptographic authority. A short transition-approval expiry is a mitigation only, not a replay-prevention guarantee; its duration is undecided.
     - **Revocation limitation (open security requirement):** early revocation of an unexpired, otherwise valid signed delivery permission is NOT cryptographically enforceable in the current design. Agent-writable state is not a revocation authority, and the `revoke` sub-action does not invalidate a valid signature. Until a durable trusted revocation mechanism exists, a permission stays usable until it expires.
     - **Initial design: short-lived and narrowly scoped.** Delivery permissions name one increment and an explicit action list, and expire quickly (lifetime to be chosen; see Open decisions). Longer-lived permissions and durable revocation are open questions. Security never depends on agent-writable revocation state: until durable revocation is designed, expiry is the only bound on a permission's lifetime.
     - Signed files may be stored in agent-writable locations, because tampering with or deleting them can only remove authority, never add it.
   - **Exact-byte binding.** The trusted owner signer (item 3) derives the record itself, shows it to the owner and signs exactly those bytes. It never signs bytes supplied by an agent. It reads Git objects with repository configuration, pagers, hooks and textconv disabled, and treats repository content as untrusted data.
   - **Verification** is unattended: `ssh-keygen -Y verify` against the trust anchor (item 2).
     - The transition script accepts a transition approval only for the single pending request it created (matching nonce), before `expiresAt`, once according to the consumed-nonce record (subject to the replay limitation), and when the spec hash it computes freshly equals `specSha256` and every other record field matches the request.
     - Each use of a delivery permission is verified afresh at the protected operation (item 4): signature, kind, repository, work id, increment, the exact permitted action, `expiresAt` and a freshly computed spec hash. A previous successful verification never stands in for the next one.
   - **Namespaces.** `approve` and `deliver` use separate signature namespaces (`ai-engineering-approve`, `ai-engineering-deliver`) as well as the `action` field, so neither can stand in for the other. The `kind` field keeps a transition approval and a delivery permission from standing in for each other; whether delivery permissions also get their own namespace is open.
   - **Agent-writable state never expands authority.** State may only narrow what a verified signature allows.
   - **Fail closed.** A missing or untrusted anchor, an unverifiable signature or any mismatch refuses the transition with an explanation. There is never a fallback to conversation.
   - `UserPromptExpansion` may at most create a pending request as a convenience. It never grants authority (D1 superseded).
   - **Commands (2026-10-16).** `/ai-engineering:approve` and `/ai-engineering:deliver` (WORK-002) change from performing interim owner-command transitions to creating a pending request (nonce, expiry) through the transition script and printing what the owner must sign through the trusted signer. They grant nothing themselves.
2. **Trust anchor (O3, deferred).** An `allowed_signers` file pinning the owner's approval public key and its permitted namespaces.
   - **Provisional preference (2026-10-13):** a root-owned verification anchor in the Claude-running account, candidate `/Library/Application Support/ai-engineering/allowed_signers`, installed once by the owner with sudo. The private signing key stays isolated in the separate approver account (G1-b).
   - The verifier refuses unless every path component is root-owned, not group- or other-writable, and not a symlink.
   - Installation waits until the architecture and signing key are settled (under G1-b the key would be a new key in the approver account).
3. **Trusted owner signer and approval path (G1, OPEN).** The owner must be able to review the exact request through a path the agent cannot modify, spoof or drive, and must be able to tell owner-initiated prompts from agent-initiated ones. Provisional architecture: **G1-b**, a separate macOS approver account (see Open decisions). Account separation alone is not treated as proof of security; G1 stays open until the G1-b proof of concept (Testing) passes and the owner separately approves closing G1.
4. **Guard integration for delivery policy.** This is the only guard change in this spec. It is an isolated commit with its own security review, built on WORK-001's classes.
   - **Delivery authority is bound to a signed delivery permission, not to a status value or any agent-writable file** (amended 2026-10-13). An agent-writable state file is never sufficient authority. At every deploy decision, including every repeat of the same deploy, the guard verifies afresh:
     - a signed delivery permission (item 1), against the trust anchor and in its namespace, whose `kind`, repository and work id match;
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
   - **Residual risk, not a sandbox (amended 2026-10-13):** "The guard is an authorisation control, not a sandbox. Signed delivery permissions do not isolate deployment credentials or network access available to the agent's operating-system account. An agent with unrestricted Bash and usable credentials may bypass guard-mediated deployment checks." Signed approvals govern only the guard's deploy decisions; they do not prevent direct deployment outside the guard. This is the existing limitation recorded in WORK-001 (non-goal: "claiming the guard is a security boundary"), [ADR-0003](../../../docs/decisions/ADR-0003-structured-action-guard.md) ("a guardrail, not a sandbox") and `docs/architecture.md` ("Hooks are guardrails, not a security sandbox").
   - **Issuing permissions:** the owner signs delivery permissions through the same trusted approval path, for one increment at a time, when that increment's policy lists a protected operation. When a permission expires, the next protected operation asks, and the owner may sign a new one. When permissions are issued in the flow (with `deliver`, or at the start of each increment) is open.
   - Anything else in a deploy class still asks.
   - **Delivery policy fields (2026-10-16):** `ephemeralDeploy` (the increment ids where preview deployment may run autonomously, provided the required accounts and credentials already exist) and `persistentEnvironments` (optional `{name, exactCommand}` entries the owner pre-authorised) are added to WORK-002's delivery policy here. Production deployment can never be expressed in policy: validation rejects it, and the guard's `production-deploy` class always asks.
5. **Rollback-resistant replay protection (2026-10-16).** Consumed-nonce tracking that the agent cannot write or roll back, so a transition approval is single-use against an agent that restores earlier state. Candidate: a store kept by the approver account (not approved). Its atomicity, accessibility at verification time, persistence, crash behaviour and rollback resistance require proof. The 2026-10-16 offline experiment showed atomic single use with an agent-writable ledger only; it is not a protected boundary.
6. **Migration from the interim mechanism (2026-10-16).** Owner-command records from WORK-002 are never imported or treated as signed authority. Items `authorised` or `delivering` under owner-command need a signed `deliver` before any protected operation runs autonomously.

Excluded (non-goals):
- The lifecycle, state model, `/deliver` rewrite and everything else that remains in WORK-002.
- Production deployment autonomy: it always asks.
- Making the guard a sandbox.
## Requirements
- Scripts are bash + jq, and every behaviour change has a case in `tests/run.sh`.
- The transition script refuses every owner-only transition without a valid signed owner approval; this is tested by calling the script directly. Direct state edits outside the script remain possible under the threat model and grant no authority.
- Signing and verification use OpenSSH `ssh-keygen -Y sign` and `-Y verify`. Proof-of-concept environment: macOS 15.7.3, OpenSSH_9.9p2 with LibreSSL 3.3.6 (`/usr/bin/ssh-keygen`); Secretive 4.0.0 according to the Homebrew cask listing before installation (the installed build was not read).
- Owner actions are declared up front: Secretive and key set-up (a new key if G1-b is adopted), the approver account (G1-b), the trusted signer, and the trust anchor (O3).
- After a Secretive, macOS or OpenSSH update, or a key rotation, the minting regression checklist (A2, A3, A5 equivalents) is re-run before signatures are trusted again.
## Security
- **Threat model (amended 2026-10-13):** an agent with unrestricted Bash, running as the owner's macOS user in the Claude-running account.
- **Withdrawn claim:** the original design said "the model can't trigger the expansion event". The 2026-10-13 spike on Claude Code 2.1.296 falsified it: a nested `claude -p` and an interactive session driven through a pseudo-terminal both fired `UserPromptExpansion`, the latter with markers identical to a human-typed command.
- **Authority forgery:**
  - tool writes to state are denied (WORK-001);
  - an owner approval needs a user-presence signature that the agent cannot produce on its own;
  - transition approvals are bound to the exact record and intended to be single-use and short-lived; single use is not rollback-resistant in the current design (replay limitation); delivery permissions are short-lived, bound to one increment and an explicit action list, and verified afresh on every use (items 1 and 4);
  - revocation state written by agents is never relied on; expiry bounds every permission.
- **B-SE proof-of-concept evidence (2026-10-13; Claude-running account, no separate approver account)**, outcomes as observed:
  - A1 PASS: the owner's signature verified; a wrong namespace and a one-byte change were rejected.
  - A2 first run INCONCLUSIVE: the owner accidentally authenticated the agent's prompt, and the agent's signature verified.
  - A2 retry PASS: each of two owner signatures needed a fresh prompt; the agent attempt one second later was refused ("agent refused operation", exit 255, no signature).
  - A3 PASS: an unattended attempt blocked for 75 s and was killed; no signature. Its prompt lingered until the owner denied it.
  - A4a: `AXIsProcessTrusted()` returned false. The System Events query was blocked without completion for 60 s (exit 137). The owner saw "iTerm wants access to control System Events"; when it was denied is unknown.
  - A4b (click and keystroke probes): NOT EXECUTED.
  - A5 PASS: the screen was locked; the attempt blocked for 75 s and was killed; no signature. After unlock a Secretive prompt for it was waiting, and the owner denied it.
  - A6: the fallbacks offered were Touch ID or the account password, both human-only.
- **G1-b evidence (2026-10-13 to 2026-10-16; test-only, scratchpad, not repository code):**
  - key isolation: a separate standard account `aiapprover` with its own Secretive key; the Claude-running account could not reach its socket, key container or keychain (Permission denied) and produced no signature;
  - admin boundary: passwordless sudo refused (B2 PASS); no remote-access listeners (B3); the shared `/Applications` Secretive copy is admin-writable (B1 FAIL), mitigated for the approver account only by a private Secretive installation;
  - v0-test signing prototype: 86 offline tests; two owner-signed records (transition and delivery permission) verified, with wrong kind, operation, nonce, swapped signature, expiry and every other namespace rejected (16/16 live checks);
  - offline replay experiment: atomic single use (1 of 20 concurrent presentations accepted, in each of 10 trials) with an agent-writable ledger, which is not a protected boundary.

  Evidence copy: `/Users/Shared/g1b-evidence-staging/` (owner copy under `/Users/Shared/g1b-test/evidence/` if made). This evidence does not close G1.
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
  - State and log files remain forgeable by a process with shell access outside tool hooks. Forged state cannot create authority without a valid signature: the transition script and the guard both verify the signed owner approval at the protected operation (items 1 and 4). It can, however, undo a state-only revocation, for example by returning a revoked item to `delivering`, while a signed delivery permission is unexpired (see the revocation limitation). Restoring pre-use state can also re-enable replay of an unexpired transition approval (see the replay limitation). It can also mislead reports or deny service. Reserved operations remain guarded, and branch protection and environment approvals remain the hard controls.
- **Preview deployment:**
  - allowed only for ephemeral deploys of the active, authorised increment, using existing credentials;
  - never production;
  - never inside a compound command;
  - never when the state is ambiguous (zero or several items delivering).
## Testing
Deterministic cases in `tests/run.sh`:
- **Owner approvals** (amended 2026-10-13), with throwaway software keys and a test anchor:
  - a valid signature over the pending request is accepted, and a second use against the current consumed-nonce record is refused;
  - refused: wrong key; wrong namespace; an `approve` signature used for `deliver` and the reverse; wrong work id or sub-action;
  - **request substitution:** a signature over a different record, a changed byte, a pending request edited after signing, or a spec changed between signing and verification is refused;
  - **replay:** a reused nonce, a nonce not pending, a signature from another repository or work item, and an expired request are refused;
  - **rollback replay (planned adversarial test):** consume a transition approval, restore the state from before it was used, then retry the same unexpired signature. With the current provisional design (consumed nonces in agent-writable state) the replay is expected to succeed: this is recorded as an **expected security failure**, not an acceptable pass. The final design must reject the replay;
  - **anchor:** missing, user-owned, group- or other-writable, or reached through a symlink is refused;
  - every `approve` sub-action (`spec`, `accept`, `defer`, `tier`, `revoke`) maps to its owner-only transition, and `defer` without an approval is refused;
  - an owner-only transition without an approval is refused, and no refusal changes state;
  - **migration (2026-10-16):** an item recorded with `source: owner-command` gains no signed authority.
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

Not yet shown by the 2026-10-16 evidence: signing from a real repository snapshot (including Git-configuration attacks), the approver repository's update source, stale prompts, and the minting regression in the approver account.
## Acceptance criteria
1. The transition script accepts an owner-only transition as authoritative only with a valid signed owner approval. Protected operations verify the relevant signed authorisation rather than inferring authority from a state field.
2. Each transition approval and each delivery permission costs the owner one deliberate review and one authentication through the trusted approval path.
3. No risk is accepted or waived, and no tier lowered, without a signed owner approval.
4. Ephemeral preview deployment runs autonomously only under the conditions in item 4, including cryptographic verification at the deploy decision and a freshly computed spec hash that matches the signed hash. State alone never grants deploy authority. A spec changed since approval never keeps deploy authority. Production always asks.
5. The G1-b proof of concept (or the owner-chosen alternative) passes, and the owner closes G1 before implementation of the approval path starts.
6. Guard verification latency at deploy decisions is measured and recorded, and any timeout derived from it fails closed.
7. The documentation states that early revocation of an unexpired signed delivery permission is not cryptographically enforceable unless durable revocation ships, and no command, message or report claims that `revoke` invalidates a valid signature.
8. Single-use enforcement of transition approvals is not considered satisfied until the final design passes the rollback replay test.
9. Owner-command records from WORK-002 never count as signed authority.
10. `scripts/check.sh` passes.
## Definition of done
- Implementation complete; deterministic tests pass
- `scripts/check.sh` passes
- Internal security review of the approval, signer, anchor, replay store and guard-policy changes (Opus) with no unresolved findings
- Independent external review passes
- Human acceptance complete
## Dependencies
- WORK-002 (state model, transition script, commands) merged and released.
- WORK-001's deploy classes and authority-store protection (merged).
## Open decisions
- **G1, trusted approval path (OPEN).** The design must provide trusted request presentation, exact-byte binding, prompt provenance, protection against stale prompts, and protection against accidental approval of agent-initiated requests. A short confirmation code alone is not sufficient while an agent can control both the request and what is displayed. Options considered:
  - **G1-a:** a root-owned terminal signer in the Claude account. It gives binding and presentation but **not provenance**: an agent can run the signer or `ssh-keygen` through a pseudo-terminal, and the resulting prompt looks the same.
  - **G1-b (provisional, selected 2026-10-13 for investigation; not approved for implementation):** a separate macOS approver account holds Secretive, a new approval key and the trusted signer. The owner switches user to review and sign.
    - Intended property: the Claude-running account cannot reach that account's key, agent socket, signer or interface, so every prompt there follows an owner action.
    - Costs (accepted by the owner, 2026-10-13, as the price of deliberate review): a second account, a new key and Secretive set-up there, a user switch per approval, an independent repository copy in the approver account, and a signature return path.
    - **Repository view (owner preference):** an independent, read-only clone or trusted snapshot in the approver account, never the Claude account's working tree. The signer reads it with hooks, repository configuration, pagers, textconv, filters and submodules disabled, treats all content as untrusted, bounds sizes and refuses symlinks.
    - **Update source: undecided.** Both GitHub (the agent can push under the owner's identity, G8) and the Claude-running account are untrusted inputs. Whatever the source, the owner independently reviews the exact commit and the specification digest the signer will sign, from the approver account's own copy, before authenticating.
    - **Request transfer (Claude account → approver):** the approver signer takes only identifiers from the pending request and treats them as untrusted: for a transition approval, repository, work id, action, sub-action, nonce and spec commit; for a delivery permission, repository, work id, increment id, the requested permitted actions and spec commit. It derives everything else from its own snapshot, and checks that a requested permission's actions are listed for that increment in the snapshot's spec. It shows the derived record and the spec content before signing. Threats to design against: substituted or swapped requests, a commit changed between fetch and display, display injection (control sequences, look-alike characters), oversized input, and denial of service.
    - **Signature return (approver → Claude account):** the signature is written to a location the approver account owns and the Claude account can only read. The verifier treats anything found there as untrusted. A transition approval is accepted only if it verifies against the anchor for a pending nonce, before expiry, and has not been consumed; making that consumed-nonce check rollback-resistant is an open requirement (below). A delivery permission is accepted only when verified at each use (item 4): signature, kind, repository, work id, increment, exact action, expiry and a fresh spec hash. The approver account never reads or executes anything the Claude account places on this path. Threats to design against: planted or replayed signatures, symlink or permission tricks on the drop location, and a stale signature for an expired request.
    - Account separation alone is not proof of security. G1 stays open until the G1-b proof of concept in Testing passes and the owner separately approves closing G1.
  - **G1-c:** a dedicated GUI approver app in the Claude account. It depends on G5 (A4b not executed), and whether Secretive's app attribution can be spoofed is unknown. Untested.
  - **G1-d:** accept the residual with G1-a's mitigations only.
- **Rollback-resistant consumed-nonce tracking (open security requirement, under G1-b):** single-use transition approvals need consumed-nonce tracking that the agent cannot write or roll back. A trusted store outside the agent's write and rollback reach (for example, kept by the approver account) is a candidate, not an approved solution. Its atomicity, accessibility at verification time, persistence and rollback resistance require proof, and the rollback replay test must pass against it.
- **Delivery permissions:** the initial design is short-lived and narrowly scoped (items 1 and 4). Still open:
  - the initial lifetime;
  - when permissions are issued in the flow;
  - whether they get their own signature namespace;
  - longer-lived permissions;
  - durable trusted revocation that does not depend on agent-writable state (an open security requirement, not an enhancement).
- **O3, trust anchor:** deferred. Provisional preference: a root-owned verification anchor in the Claude-running account, with the private signing key isolated in the approver account.
- **Approver repository update source:** undecided (see G1-b).
- **Guard rule scope:** confirm ask for the coordinator and deny for specialists on nested Claude launches and signer use (defence in depth only).
- **Admin-boundary residual (2026-10-16):** the Claude-running account is an administrator; B1 (admin-writable shared application copies) and the untested X6 and B4 need an owner decision before production activation.
