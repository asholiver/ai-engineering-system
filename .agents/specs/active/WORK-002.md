# Work Specification
## Status
**Current status (2026-10-19): delivery authorised.** The owner accepted the Path B amendment (PR #8 at `43afbdc`, merged as `164d821`) and authorised delivery of the v0.3.0 lifecycle scope on 2026-10-19, within this spec and ADR-0004. Merge and deployment still need explicit owner approval. G1 stays OPEN; signed approvals and autonomous deployment remain WORK-004.

Previous status (2026-10-16, history): Path B split, proposed, pending owner review. The owner chose Path B on 2026-10-16: this spec keeps the lifecycle, state, `/deliver` rewrite and the rest of the delivery workflow, with an interim owner-command mechanism for owner-only transitions (Scope item 3). Signed owner approvals, replay protection, the trust anchor and autonomous deployment move unchanged to [WORK-004](WORK-004.md). The interim mechanism grants no new guard permission, no autonomous deployment right and no security authority. Implementation and delivery are not authorised until the owner accepts this amendment and the ADR-0004 interim mechanism, and separately authorises delivery. G1 stays OPEN (WORK-004).

Previous status (2026-10-13, history): approved in principle for design. The revised authority mechanism (signed owner approvals, Scope items 3 and 7) is pending security review and G1 closure. It replaces `UserPromptExpansion` tokens after the spike showed that agents can trigger the event (D1 superseded). G1 (trusted approval path) is OPEN. G1-b (separate macOS approver account) is the provisional architecture for investigation, not an approved implementation. The trust anchor (O3) is deferred. Implementation and delivery are not authorised.

Original status (history): Approved (by Ashley Oliver, 2026-10-06), in principle, with owner decisions D1–D6 incorporated as recorded in `WORK-001-planning.md`. Delivery is not authorised; it may start only after the gate-bootstrap PR (D5) is merged and the owner explicitly authorises it.
## Work ID
WORK-002: Work lifecycle and authority (v0.3 PR B)
## Objective
Move work authority out of conversation into explicit state that lifecycle commands are the only supported way to change. Once the owner authorises delivery of an approved spec, routine implementation proceeds without "continue", "approve fix" or "approve work-branch push" prompts. Every legitimate interruption maps to one of five triggers, and intent never changes without the owner. In v0.3.0 owner-only transitions use the interim owner-command mechanism (Scope item 3), which is a workflow record, not security authority: every protected operation keeps its current owner controls. Signed owner approvals and autonomous deployment follow in WORK-004 (amended 2026-10-16).

Decision record: [ADR-0004](../../../docs/decisions/ADR-0004-work-authority-and-lifecycle.md). Programme context: [WORK-001-planning.md](WORK-001-planning.md).
## Scope
Included:
1. **Work-item state.** `.agents/specs/active/WORK-NNN.state.json` (schema under Data), committed with the work. One transition script (`workstate.sh` or equivalent, bash + jq) is the only **supported** state-transition interface; it is not the only possible writer. Every transition through it validates the current status and the actor requirement; owner-only transitions require the interim owner command (Scope item 3). Under the unrestricted-Bash threat model, direct edits to state remain possible. State is a workflow record: no guard decision and no protected operation reads it as authority (Scope item 7; amended 2026-10-16).
2. **Lifecycle:** `proposed → approved → authorised → delivering → (blocked ↔ delivering) → done → archived`, with `paused` reachable from `authorised`, `delivering` or `blocked`. Transitions and actors:

   | Transition | Actor | Requirement |
   | :- | :- | :- |
   | create / → proposed | coordinator in `/plan` | spec exists |
   | proposed → approved | owner | `approve` approval; records the spec content hash and commit |
   | approved → authorised → delivering | owner | `deliver` approval; spec hash still equals the approved hash; records the delivery policy from the spec (informational copy; see Scope item 6) |
   | delivering → blocked | coordinator | a decision record with a trigger class |
   | blocked → delivering | owner answer | see Decisions below |
   | accept or waive risk, defer a finding, lower a tier, revoke | owner | `approve` owner command with that sub-action (`revoke` changes state only) |
   | raise a tier, record a finding fixed or invalid (non-security), record gate or review evidence | coordinator | none |
   | pause | owner or coordinator | none (pausing is always safe) |
   | resume a paused item | owner | `deliver` approval; returns the item to the status it was paused from |
   | delivering → done | coordinator | every increment merged (observed through Git) |
   | any change to the spec content | anyone | status returns to `proposed`, and delivery stops at the next transition check |

   In v0.3.0, "`approve` approval" and "`deliver` approval" in this table mean the interim owner command (Scope item 3). WORK-004 replaces them with signed approvals (amended 2026-10-16).

3. **Interim owner-command transitions (v0.3.0; amended 2026-10-16).** Defined in [ADR-0004](../../../docs/decisions/ADR-0004-work-authority-and-lifecycle.md).
   - Owner-only transitions are performed by the human-only commands (Scope item 4) through the transition script, which records them with `source: "owner-command"`, the command, the time and the spec hash.
   - **Not security authority.** The 2026-10-13 spike showed an agent can trigger a slash command, and state is agent-forgeable. An owner-command record is therefore never proof of owner intent and is never treated as a signed approval, now or after WORK-004.
   - **What it may affect:** only the plugin's own workflow instructions, chiefly whether `/deliver` proceeds without its own "continue", "approve fix" and "approve work-branch push" questions. These were instructions, not controls: the guard does not reserve non-default-branch pushes or PR creation today.
   - **What it never affects:** guard and hook decisions (no guard code reads state; Scope item 7), deploy classes (every deploy still asks), reserved operations, Claude Code permission prompts, branch protection and the owner's merge.
   - **Ratification at merge.** Owner-command decisions that accept, waive or defer risk, or lower a tier, are listed in the readiness report. The owner's review and merge of the increment PR is the control that ratifies them.
   - Signed owner approvals, replay protection, the trust anchor and the trusted approval path (G1) are WORK-004.
4. **One new human-only command:** `/ai-engineering:approve <WORK-ID> [spec | accept <finding-id> | defer <finding-id> | tier <increment-id> <0|1|2> | revoke]` with `disable-model-invocation: true` (D2). `/ai-engineering:deliver <WORK-ID>` authorises, or resumes a paused item. A scope extension means amending the spec, then `approve`, then `deliver`.
   - `accept` records acceptance or waiver of a finding's risk. `defer` records an owner decision to defer a finding to later work. Each `approve` sub-action corresponds to exactly one of the owner-only transitions assigned to `approve` in the table in Scope item 2: approving a spec, accepting or waiving risk, deferring a finding, lowering a tier and revoking. Each of those transitions has a sub-action.
   - `/ai-engineering:deliver` performs the owner-only delivery transitions in that table: `approved → authorised → delivering`, and resuming a paused item. These transitions have no `approve` sub-action.
   - The commands perform the owner-only transition through the transition script with `source: "owner-command"` (Scope item 3). In WORK-004 they will instead create a pending request for the owner to sign (amended 2026-10-16).
   - **Approval and delivery authorisation stay distinct.** An `approve` approval can never authorise or resume delivery. A `deliver` approval can never approve a spec, accept or waive risk, defer a finding, lower a tier or revoke. `deliver` on an item that isn't `approved` (or `paused`) is refused.
5. **`/plan` changes.**
   - New spec template: intent only, plus three new sections:
     - Increments, with the proposed tier and reasons for each;
     - Delivery policy;
     - Owner actions.
   - The template drops "Implementation state" and "Review state".
   - `/plan` creates or updates the state in `proposed`, commits nothing on its own, and ends by telling the owner to type `/ai-engineering:approve <WORK-ID>`.
   - Conversational approval never changes status.
6. **Delivery policy**, declared in the spec and copied into state at authorisation. Fields:
   - `pushWorkBranch` (default true);
   - `openPullRequest` (default true; draft or ready per policy; never merge).

   Deployment fields (`ephemeralDeploy`, `persistentEnvironments`) are WORK-004; validation rejects them in v0.3.0 with a pointer to WORK-004. Production deployment can never be expressed in policy, and the guard's `production-deploy` class always asks (amended 2026-10-16).
7. **No guard change (amended 2026-10-16).** WORK-002 does not change `guard-bash.sh` or any hook decision. Guard integration for delivery policy (signed delivery permissions, autonomous ephemeral and persistent deploys) moves to WORK-004, Scope item 4. Every deploy class, including `ephemeral-deploy`, keeps asking whatever the work-item state says. The guard's protection of state files (WORK-001) is unchanged.
8. **`/deliver` rewrite.**
   - Preconditions read state, not prose.
   - It prints a display-only delivery summary (scope, increments, tiers, policy, planned owner actions) without asking a confirmation question.
   - It plans tasks as a dependency graph by file area.
   - It runs tasks sequentially in one checkout by default; parallel worktrees for independent tasks are opt-in. Starting an increment from the updated default branch asks one guard confirmation, because WORK-001's guard asks on branch switches and merges and this spec makes no guard change. That confirmation never replaces, suppresses or pre-authorises any other guard prompt (deploy, merge, publish, protected push or other reserved operation). With parallel worktrees opted in, each worktree merge also asks (amended 2026-10-19, owner decision).
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
    4. a reserved operation: every protected operation, including every deploy, still asks in v0.3.0 (amended 2026-10-16);
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
- Signed owner approvals, the trusted approval path (G1), the trust anchor (O3), replay protection, revocation and autonomous deployment (moved to WORK-004, 2026-10-16).
## Requirements
- Scripts are bash + jq, and every behaviour change has a case in `tests/run.sh`.
- Always-loaded context stays within `scripts/check.sh` budgets. New commands use `disable-model-invocation: true`.
- State writes are atomic (write then rename) and validated against the schema before replacing the file. A corrupt or unreadable state file stops delivery with a clear message; the script never repairs it silently.
- The transition script refuses every owner-only transition that does not come from the interim owner command, and records the source; this is tested by calling the script directly. Direct state edits outside the script remain possible under the threat model and grant no authority, because nothing grants authority from state (Scope items 3 and 7; amended 2026-10-16).
- Owner actions are declared up front (for example `gh` authentication).
## Business rules
- Conversation never grants authority.
- A spec change invalidates approval.
- v0.2 authority is never imported as v0.3 authority.
- Risk is never accepted or waived silently.
- Production deployment, merge, release, publish, default-branch push, destructive operations, and creating or changing accounts, credentials or consequential external resources always need the owner.
## Architecture
Affected areas:
- `plugins/ai-engineering/scripts/`:
  - new transition script (amended 2026-10-16: no signature verification; see WORK-004);
  - new wait helper;
  - `inject-standards.sh` (banner).

  `guard-bash.sh` is unchanged (Scope item 7).
- `hooks/hooks.json` (no UserPromptExpansion entry is required; amended 2026-10-13).
- `skills/plan`, `skills/deliver`, `skills/review` (deliver calls it; content changes belong to WORK-003), `skills/setup` (+ templates), and a new `skills/approve`.
- `agents/{frontend,backend,platform}.md` (handoff and decision-reporting wording).
- `docs/`, `tests/run.sh`, `scripts/check.sh` (only if new budgets or checks are needed).

Exact script names and the internal schema layout are left to the implementer. The canonical signed-approval record format belongs to WORK-004 (amended 2026-10-16).
## Data
Conceptual state:
```
{ schemaVersion, id, title, status,
  spec:      { path, contentSha256, approvedCommit },
  approval:  { by, at, specSha256, source: "owner-command" | "imported", importedFrom? } | null,
  delivery:  { by, at, specSha256, policy } | null,
  ownerActions[]: { id, description, increment, status, requestedAt, doneAt },
  decisions[]:    { id, trigger, question, options, askedAt, answeredAt, answer, source: "owner-command" | "conversation", by },
  increments[]:   { id, title, status: planned|active|ready|merged, proposedTier, branch, pr,
                    baseSha, headSha, mergeSha, recoveries },
  findings[]:     { id, source, severity, summary, disposition: open | fixed(sha) | invalid(evidence, confirmedBy) | owner(decisionId) },
  history[]:      { at, transition, actor, approvalId? } }
```
WORK-003 adds tier, gate and review-ledger fields to `increments[]`.
## API
- Transition script: subcommands for each transition. Exit codes distinguish success, invalid transition, missing owner command, schema error and spec-hash mismatch. The exact numbering is left to the implementer.
- Guard: unchanged (Scope item 7).
- Wait helper: `checks <pr|sha>` and `merge <pr>` modes with a timeout; prints one verdict line.
## UI
- The owner types `/ai-engineering:approve` and `/ai-engineering:deliver`. In v0.3.0 there is no signing step (amended 2026-10-16).
- The delivery summary is printed, not asked.
- Escalations state their trigger class, the options and a recommendation.
## Security
- **Threat model (amended 2026-10-13):** an agent with unrestricted Bash, running as the owner's macOS user in the Claude-running account.
- **Interim owner commands are not authority (amended 2026-10-16).** An agent can trigger the human-only commands (2026-10-13 spike) and can forge state. Accepted consequence: an agent could move an item to `approved`, `authorised` or `delivering` without the owner and then proceed with routine work without asking. Every resulting change still reaches the default branch only through a PR the owner reviews and merges, and every reserved or protected operation still asks.
- **No authority from state:** the guard and protected operations never read state as authority (Scope item 7). Forged state can mislead reports, skip skill-level questions or deny service; it cannot widen what the guard allows.
- **Prompt injection** from issues, dependencies or tool output can at most trigger the same unauthorised workflow transitions as above. Agents treat tool output as data.
- **Wait helper:** authenticated `gh` only; responses validated; never logs tokens.
- Signed approvals, the B-SE and G1-b evidence and residual risks G1–G8 are in WORK-004.
## Scalability and reliability
- Bounded retries, timeouts and backoff for waits.
- One automatic recovery per stalled task.
- Atomic state writes.
- Several work items may exist. (The deploy allowance that requires exactly one item in `delivering` is WORK-004; amended 2026-10-16.)
## Observability
- State timestamps and `history[]` support these metrics: authorisation-to-readiness time, owner-wait proportion, interruptions by trigger, planned owner actions measured separately, and recoveries.
- `log.md` holds the narrative.
## Testing
Deterministic cases in `tests/run.sh`:
- **Transition table:** every allowed transition succeeds with the right actor and approval; every disallowed transition fails with the specific exit code.
- **Owner commands** (amended 2026-10-16):
  - every owner-only transition succeeds through the owner command and records `source: "owner-command"`;
  - an owner-only transition requested without the owner command is refused, and no refusal changes state;
  - every `approve` sub-action (`spec`, `accept`, `defer`, `tier`, `revoke`) maps to its owner-only transition;
  - `deliver` on an item that isn't `approved` (or `paused`) is refused.
- **Intent/implementation boundary:**
  - (a) A prompt "we also need to update the README" creates no approval. A `proposed` item stays `proposed`, and `deliver` preconditions refuse it.
  - (b) During `delivering`, a spec edit adding a README requirement changes the spec hash, and the next transition returns the item to `proposed` and stops delivery.
- **Policy validation:** a spec policy containing a production deploy, `ephemeralDeploy` or `persistentEnvironments` is rejected at approval, with a pointer to WORK-004 for the deployment fields (amended 2026-10-16).
- **Guard parity** (amended 2026-10-16): for a representative set of reserved and deploy commands (`vercel deploy`, `vercel --prod`, a default-branch push, a merge, a publish), the guard's decision is identical with no state, with an honest `delivering` state, and with forged state (`delivering`, increment listed). Existing WORK-001 guard cases are unchanged.
- **Import:** v0.2 spec fixtures (Draft, Approved, legacy state sections, Approved with a partially delivered history):
  - the resulting state is never `authorised` or `delivering`;
  - approval `source: imported` with the approver and date taken from the Status line;
  - legacy sections untouched;
  - the import is idempotent.
- **Wait helper** with a fake `gh` on `PATH`: success, failure, timeout, unauthenticated, rate-limit error payload and malformed JSON each produce the correct verdict. No unauthenticated network call is ever made.
- **Setup:** the template contains `worktree.baseRef: "head"`. The banner prints the version and root, within budget.

Signed approvals, guard policy and the G1-b proof of concept are tested in WORK-004 (moved 2026-10-16).

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
- **Interim mechanism (2026-10-16):** owner commands can be triggered by an agent (Security). Mitigated by keeping every guard and platform control unchanged and listing owner-command decisions in readiness for the owner's merge review.
- **Owner friction:** every deploy and reserved operation still asks in v0.3.0; autonomous preview deploys wait for WORK-004.
- **Parallel worktrees** need dependencies installed (`.worktreeinclude`). Document; fall back to sequential when installation fails, recording why.
- **Background merge waits across long gaps.** Bounded; an expired wait records "waiting for owner merge" as a planned owner action, not an interruption.
## Acceptance criteria
1. The transition script is the only supported state-transition interface. Owner-only transitions require the interim owner command and are recorded with `source: "owner-command"`. No guard decision or protected operation reads state as authority (amended 2026-10-16).
2. `/ai-engineering:approve` and `/ai-engineering:deliver` perform their transitions without guard noise and without a signing step (amended 2026-10-16).
3. A conversational statement never changes status or grants delivery authority (boundary tests pass).
4. After `/deliver`, routine fixes, work-branch pushes and PR updates proceed without owner prompts (E1).
5. Interruptions occur only for the five triggers, each recorded with its trigger class.
6. HIGH-or-above fixes appear in the readiness report. No risk is accepted or waived silently: each owner-command decision that accepts, waives or defers risk, or lowers a tier, is listed in the readiness report (amended 2026-10-16).
7. A spec change returns the item to `proposed`.
8. Specialists never perform Git writes. The coordinator owns branches, commits, merges, pushes and PRs.
9. Sequential execution is the default; parallel worktrees are opt-in and documented. The only guard confirmation added by routine delivery is one per increment start (plus one per worktree merge when parallel is opted in), and it pre-authorises nothing else (amended 2026-10-19).
10. Specialist handoffs exclude the log and legacy state sections.
11. Stalls are recovered once automatically. External waits run in the background, authenticated, validated and bounded.
12. Guard parity: every deploy class and reserved operation asks exactly as before WORK-002, whatever the state says (test above). No autonomous deployment in v0.3.0; production always asks (amended 2026-10-16).
13. v0.2 work items import without fabricated authority.
14. The session banner shows the active plugin version and root.
15. `scripts/check.sh` passes.
16. The documentation states that interim owner-command transitions are not security authority, and no command, message or report claims otherwise (amended 2026-10-16; the former criteria 16–19 on G1, latency, revocation and rollback replay move to WORK-004).
## Definition of done
- Implementation complete; deterministic tests pass; E1–E3 evidence recorded
- `scripts/check.sh` passes
- Internal security review of the state, transition script, owner-command mechanism and guard parity (Opus) with no unresolved findings (amended 2026-10-16)
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
  - F0-S2's account, credential and resource steps are declared up front as owner actions. Preview deploys ask in v0.3.0; autonomous preview deployment waits for WORK-004 (amended 2026-10-16);
  - F0-S3 production deployment remains owner-run.
- **Upgrading:** the documented procedure must check the session banner, because an existing user-level marketplace registration can keep an older release active.
## Documentation
- `README.md`: commands (add `approve`), lifecycle, what runs without prompts.
- `docs/architecture.md`: state and authority, lifecycle, triggers, Git ownership, concurrency default, waits and recovery, delivery policy.
- `docs/consuming-project.md`: import, worktree default and opt-out, `gh` authentication requirement, upgrade verification through the banner.
- `docs/model-policy.md`: retry and recovery wording.
- `versions/CHANGELOG.md`.
## Independent review
- **Internal review.** Opus security review of the transition script, the owner-command mechanism and guard parity (amended 2026-10-16).
- **External review.** CodeRabbit on the PR at its head SHA, with no unresolved actionable findings (D5 arrangement while v0.2.0 governs).
- **Gate scripts.** Under v0.2 the gate commands come from the base ref, but `tests/run.sh` and `scripts/check.sh` are executed from the change itself. Reviewers must check every diff to those two files, and a weakened or removed check is a blocking finding.
- **Owner acceptance.** The owner checks the transition table and the Business rules list.
## Dependencies
- WORK-001 is merged; this spec makes no guard change (amended 2026-10-16).
- WORK-003 builds on this state model.
- WORK-004 builds on this state model and replaces the interim owner-command mechanism.
## Settled owner decisions
- Work-branch pushes are autonomous once delivery is authorised.
- Remediation depends on fix versus accept, not severity.
- No pre-authorisation write hook.
- One PR per meaningful increment by default (not an invariant).
- Parallel worktrees by default with an opt-out. **Amended 2026-10-19:** sequential by default, parallel worktrees opt-in; one guard confirmation per increment start (Scope item 8).
- Coordinator-owned Git.
- Deployment authority as clarified on 2026-10-06 (preview autonomous under policy; persistent only if pre-authorised; production owner-only). **Amended 2026-10-13:** preview and pre-authorised persistent deploys run autonomously only while a valid signed delivery permission covers that increment and action; on expiry or absence they pause for fresh owner approval. **Amended 2026-10-16:** autonomous deployment moves to WORK-004; in v0.3.0 every deploy asks.
- The command-token mechanism. **Superseded 2026-10-13** by owner signatures (now WORK-004; interim owner commands in v0.3.0, Scope item 3).
- D1: tokens come from `UserPromptExpansion`, never `UserPromptSubmit`. **Superseded 2026-10-13:** `UserPromptExpansion` fires for agent-launched sessions too, so it cannot attest the owner. It may only create pending requests.
- B-SE (user-presence owner signatures) selected as the baseline (2026-10-13), subject to G1 and O3. **Moved to WORK-004 (2026-10-16).**
- **Path B (2026-10-16):** split signed approvals and autonomous deployment into WORK-004; ship the lifecycle in v0.3.0 with interim owner-command transitions that grant no security authority.
- D2: the human-only `/ai-engineering:approve` command exists, and approval stays distinct from delivery authorisation.
- D3: no main-session model requirement.
- D5: the gate-bootstrap PR is merged before this work starts, and CodeRabbit is the external reviewer for this PR.
## Open decisions
- G1, rollback-resistant nonce tracking, delivery-permission design, O3, the approver repository update source and guard rule scope moved to WORK-004 (2026-10-16).
- None remain for this spec beyond the owner's acceptance of the Path B amendment.

D2, D3 and D5 remain resolved (see `WORK-001-planning.md`); D1 is superseded.
## Implementation state
<!-- v0.2 deliver records task status and verdict lines here. Keep entries to one line each; put detailed evidence in WORK-002.log.md. -->
- Delivery (owner-authorised 2026-10-19; branch `feature/work-002-lifecycle` from `f71b540`; v0.2 deliver, sequential in the main checkout; playbook: feature; Opus security review required):
  - B1 backend: state schema, transition script, owner-command source, policy validation, v0.2 import, guard-parity tests (Scope 1–3, 6, 7, 18; AC1, 3, 7, 12, 13). Status: done; `workstate.sh`; `GATE fast: PASSED (exit 0) command: tests/run.sh` (3069 passed, 0 failed); guard and hook files unchanged.
  - B2 backend: `/approve` skill, `/deliver` rewrite, `/plan` template, `/setup` (baseRef, import, banner), agent wording, wait helper, recovery (Scope 4, 5, 8–17; AC2, 4–6, 8–11, 14, 16). Status: B2a done (approve skill, deliver entry transition, plan template, setup, banner, agent wording, `wait-github.sh`); `GATE full: PASSED (exit 0) command: scripts/check.sh` (3160 passed, 0 failed). B2b done (`/deliver` rewrite; `review` records evidence for items with state); `GATE full: PASSED (exit 0) command: scripts/check.sh` (3196 passed, 0 failed).
  - B3 coordinator: docs, CHANGELOG, E1–E3 evidence in a scratch project, gates, reviews. Status: docs and CHANGELOG done with B2b; QA and Opus security review in progress; E1–E3 planned (owner action: type `/approve` and `/deliver` in a scratch project).
## Review state
<!-- v0.2 review records its status block here. -->
-
