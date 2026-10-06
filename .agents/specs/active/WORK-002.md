# Work Specification
## Status
Approved (by Ashley Oliver, 2026-10-06), in principle, with owner decisions D1–D6 incorporated as recorded in `WORK-001-planning.md`. Delivery is not authorised; it may start only after the gate-bootstrap PR (D5) is merged and the owner explicitly authorises it.
## Work ID
WORK-002: Work lifecycle and authority (v0.3 PR B)
## Objective
Move work authority out of conversation into explicit state that only lifecycle commands can change. Once the owner authorises delivery of an approved spec, routine implementation runs to readiness with no "continue", "approve fix" or "approve work-branch push" prompts. Every legitimate interruption maps to one of five triggers, and intent never changes without the owner.

Decision record: [ADR-0004](../../../docs/decisions/ADR-0004-work-authority-and-lifecycle.md). Programme context: [WORK-001-planning.md](WORK-001-planning.md).
## Scope
Included:
1. **Work-item state.** `.agents/specs/active/WORK-NNN.state.json` (schema under Data), committed with the work. One transition script (`workstate.sh` or equivalent, bash + jq) is the only writer. Every transition validates the current status, the actor requirement and, for owner-only transitions, a fresh matching authority token.
2. **Lifecycle:** `proposed → approved → authorised → delivering → (blocked ↔ delivering) → done → archived`, with `paused` reachable from `authorised`, `delivering` or `blocked`. Transitions and actors:

   | Transition | Actor | Requirement |
   | :- | :- | :- |
   | create / → proposed | coordinator in `/plan` | spec exists |
   | proposed → approved | owner | `approve` token; records the spec content hash and commit |
   | approved → authorised → delivering | owner | `deliver` token; spec hash still equals the approved hash; records the delivery policy from the spec |
   | delivering → blocked | coordinator | a decision record with a trigger class |
   | blocked → delivering | owner answer | see Decisions below |
   | accept or waive risk, defer a finding, lower a tier, revoke | owner | `approve` token with that sub-action |
   | raise a tier, record a finding fixed or invalid (non-security), record gate or review evidence | coordinator | none |
   | pause | owner or coordinator | none (pausing is always safe) |
   | resume a paused item | owner | `deliver` token; returns the item to the status it was paused from |
   | delivering → done | coordinator | every increment merged (observed through Git) |
   | any change to the spec content | anyone | status returns to `proposed`, and delivery stops at the next transition check |

3. **Authority tokens: silent and non-blocking.**
   - A plugin hook on `UserPromptExpansion` fires only when the human types a slash command (D1). `UserPromptSubmit` is deliberately not used, because it also fires for scheduled tasks, background-subagent reports and cross-session messages. When `command_name` is the plugin's `approve` or `deliver` command, it writes a one-time token into the authority store, recording:
     - command;
     - arguments;
     - session id;
     - time;
     - the SHA-256 of the prompt;
     - a nonce.
   - The hook never blocks, never prompts and emits no output beyond optional debug logging.
   - Tokens expire (for example 30 minutes, same session) and are consumed on use.
   - If the event is unavailable on the running Claude Code version, owner-only transitions fail closed with an explanation. They never fall back to conversation.
4. **One new human-only command:** `/ai-engineering:approve <WORK-ID> [spec | accept <finding-id> | defer <finding-id> | tier <increment-id> <0|1|2> | revoke]` with `disable-model-invocation: true` (D2). `/ai-engineering:deliver <WORK-ID>` authorises, or resumes a paused item. A scope extension means amending the spec, then `approve`, then `deliver`.
   - `accept` records acceptance or waiver of a finding's risk. `defer` records an owner decision to defer a finding to later work. Each `approve` sub-action corresponds to exactly one of the owner-only transitions assigned to `approve` in the table in Scope item 2: approving a spec, accepting or waiving risk, deferring a finding, lowering a tier and revoking. Each of those transitions has a sub-action.
   - `/ai-engineering:deliver` performs the owner-only delivery transitions in that table: `approved → authorised → delivering`, and resuming a paused item. These transitions have no `approve` sub-action.
   - **Approval and delivery authorisation stay distinct.** An `approve` token can never authorise or resume delivery. A `deliver` token can never approve a spec, accept or waive risk, defer a finding, lower a tier or revoke. `deliver` on an item that isn't `approved` (or `paused`) is refused.
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
   - `openPullRequest` (default true; draft or ready per policy; never merge);
   - `ephemeralDeploy`: the increment ids where preview deployment may run autonomously, provided the required accounts and credentials already exist;
   - `persistentEnvironments`: optional `{name, exactCommand}` entries the owner pre-authorised.

   Production deployment can never be expressed in policy: validation rejects it, and the guard's `production-deploy` class always asks.
7. **Guard integration for delivery policy.** This is the only guard change in this spec. It is an isolated commit with its own security review, built on WORK-001's classes.
   - **Delivery authority is bound to the approved spec content, not to a status value.** At the moment the guard decides on any deploy command, it computes the SHA-256 of the spec file's current content itself. It never trusts a stored "current" hash. It compares that value with both `approval.specSha256` and `delivery.specSha256`.
     - If either differs, or the spec file can't be read, the policy grants nothing and the command asks. This holds even if the state still says `delivering`, and even before any later lifecycle transition notices the change.
   - **`ephemeral-deploy`:** produces no decision when all of these hold:
     - the freshly computed spec hash matches both recorded hashes;
     - the command is alone (a context prefix is allowed);
     - exactly one work item in the repository is `delivering`;
     - its active increment is listed in `ephemeralDeploy`;
     - its state was written by the transition script, not edited by a tool (tool writes are denied by WORK-001).

     Otherwise it asks.
   - **`persistentEnvironments`:** produces no decision only on an exact match of an approved `exactCommand`, run alone, and only when the freshly computed spec hash matches both recorded hashes.
   - Anything else in a deploy class still asks.
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
    4. a reserved operation;
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
- Owner-only transitions are impossible without a token. This is tested by calling the script directly.
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
  - new token hook script;
  - new wait helper;
  - `inject-standards.sh` (banner);
  - `guard-bash.sh` (policy integration only).
- `hooks/hooks.json` (UserPromptExpansion entry).
- `skills/plan`, `skills/deliver`, `skills/review` (deliver calls it; content changes belong to WORK-003), `skills/setup` (+ templates), and a new `skills/approve`.
- `agents/{frontend,backend,platform}.md` (handoff and decision-reporting wording).
- `docs/`, `tests/run.sh`, `scripts/check.sh` (only if new budgets or checks are needed).

Exact script names, the internal schema layout and the token file format are left to the implementer.
## Data
Conceptual state:
```
{ schemaVersion, id, title, status,
  spec:      { path, contentSha256, approvedCommit },
  approval:  { by, at, specSha256, source: "token" | "imported", importedFrom? } | null,
  delivery:  { by, at, specSha256, policy } | null,
  ownerActions[]: { id, description, increment, status, requestedAt, doneAt },
  decisions[]:    { id, trigger, question, options, askedAt, answeredAt, answer, source: "token" | "conversation", by },
  increments[]:   { id, title, status: planned|active|ready|merged, proposedTier, branch, pr,
                    baseSha, headSha, mergeSha, recoveries },
  findings[]:     { id, source, severity, summary, disposition: open | fixed(sha) | invalid(evidence, confirmedBy) | owner(decisionId) },
  history[]:      { at, transition, actor, tokenId? } }
```
WORK-003 adds tier, gate and review-ledger fields to `increments[]`.
## API
- Transition script: subcommands for each transition. Exit codes distinguish success, invalid transition, missing or expired token, schema error and spec-hash mismatch.
- Token hook: UserPromptExpansion input in; no output.
- Wait helper: `checks <pr|sha>` and `merge <pr>` modes with a timeout; prints one verdict line.
## UI
- The owner types `/ai-engineering:approve` and `/ai-engineering:deliver`.
- The delivery summary is printed, not asked.
- Escalations state their trigger class, the options and a recommendation.
## Security
- **Authority forgery:**
  - tool writes to state and tokens are denied (WORK-001);
  - tokens are one-time, short-lived, bound to session, command, work id and prompt hash;
  - the model can't trigger the expansion event (it fires only for typed commands, and the commands disable model invocation).
  - Residual risk, documented: a process with shell access can still forge files outside tool hooks. Authority is tamper-evident, not tamper-proof. Reserved operations remain guarded, and branch protection and environment approvals remain the hard controls.
- **Prompt injection** from issues, dependencies or tool output can't create tokens. Agents treat tool output as data.
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
- **Transition table:** every allowed transition succeeds with the right actor and token; every disallowed transition fails with the specific exit code.
- **Tokens:**
  - minted only for `approve` and `deliver` expansions of plugin commands;
  - not minted for other commands, or for plain prompt text containing "/ai-engineering:deliver" or "approved";
  - an expired, reused, wrong-work-id or wrong-session token is refused;
  - an `approve` token can't authorise or resume delivery, and a `deliver` token can't approve, accept or waive risk, defer a finding, lower a tier or revoke;
  - every `approve` sub-action (`spec`, `accept`, `defer`, `tier`, `revoke`) maps to its owner-only transition, and `defer` without a token is refused;
  - an owner-only transition without a token is refused.
- **Intent/implementation boundary:**
  - (a) A UserPromptExpansion-free prompt "we also need to update the README" mints nothing. A `proposed` item stays `proposed`, and `deliver` preconditions refuse it.
  - (b) During `delivering`, a spec edit adding a README requirement changes the spec hash, and the next transition returns the item to `proposed` and stops delivery.
- **Policy validation:** a spec policy containing a production deploy, or `persistentEnvironments` without an exact command, is rejected at approval.
- **Guard and policy:** with fixtures for state and policy:
  - `vercel deploy` → none when delivering and the increment is listed;
  - → ask when the item is `authorised` but not `delivering`, when the increment isn't listed, when two items are delivering, or when the command is compound with another effectful command;
  - `vercel --prod` → always ask;
  - with the item still `delivering` and the increment listed, but the spec file edited (committed or not) since approval → `vercel deploy` asks, and a persistent exact match asks. The state is left untouched, proving the check happens at the deploy decision itself;
  - a missing or unreadable spec file → ask;
  - a persistent exact match → none; a near-miss → ask.
- **Import:** v0.2 spec fixtures (Draft, Approved, legacy state sections, Approved with a partially delivered history):
  - the resulting state is never `authorised` or `delivering`;
  - approval `source: imported` with the approver and date taken from the Status line;
  - legacy sections untouched;
  - the import is idempotent.
- **Wait helper** with a fake `gh` on `PATH`: success, failure, timeout, unauthenticated, rate-limit error payload and malformed JSON each produce the correct verdict. No unauthenticated network call is ever made.
- **Setup:** the template contains `worktree.baseRef: "head"`. The banner prints the version and root, within budget.

End-to-end scenarios run deliberately in a scratch project, using unreleased source per the self-development protocol in `WORK-001-planning.md`. Evidence goes in `WORK-002.log.md`.
- **E1.** Plan → approve → deliver a two-task spec with a planted failing test and a planted in-intent QA finding. Expected:
  - no continue, fix or push prompts;
  - work branch pushed to a local bare remote;
  - both remediations recorded;
  - readiness reached.
- **E2.** A mid-delivery conversational "we also need to update the README". Expected: recorded as a trigger-1 scope proposal, the README untouched, delivery continues on the approved scope.
- **E3.** A stalled specialist (simulated with a deliberately hanging task) is resumed once, then escalated.
## Risks
- **UserPromptExpansion behaviour** (exact `command_name` format for plugin skills, availability on older Claude Code versions). Verify early in implementation; fail closed.
- **Parallel worktrees** need dependencies installed (`.worktreeinclude`). Document; fall back to sequential when installation fails, recording why.
- **Background merge waits across long gaps.** Bounded; an expired wait records "waiting for owner merge" as a planned owner action, not an interruption.
## Acceptance criteria
1. Only the transition script changes state, and every owner-only transition requires a valid token.
2. `/ai-engineering:approve` and `/ai-engineering:deliver` mint tokens silently, with no new prompt or guard noise.
3. A conversational statement never changes status or grants delivery authority (boundary tests pass).
4. After `/deliver`, routine fixes, work-branch pushes and PR updates proceed without owner prompts (E1).
5. Interruptions occur only for the five triggers, each recorded with its trigger class.
6. HIGH-or-above fixes appear in the readiness report. No risk is accepted or waived without an owner token.
7. A spec change returns the item to `proposed`.
8. Specialists never perform Git writes. The coordinator owns branches, commits, merges, pushes and PRs.
9. Parallel worktrees are the default, and the opt-out is documented.
10. Specialist handoffs exclude the log and legacy state sections.
11. Stalls are recovered once automatically. External waits run in the background, authenticated, validated and bounded.
12. Ephemeral preview deployment runs autonomously only under the conditions in Scope item 7, including a spec hash computed fresh at the deploy decision that matches the approved hash. A spec changed since approval never keeps deploy authority, whatever the recorded status. Production always asks.
13. v0.2 work items import without fabricated authority.
14. The session banner shows the active plugin version and root.
15. `scripts/check.sh` passes.
## Definition of done
- Implementation complete; deterministic tests pass; E1–E3 evidence recorded
- `scripts/check.sh` passes
- Internal security review of the token, state and guard-policy changes (Opus) with no unresolved findings
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
- **Internal review.** Opus security review of the token hook, transition script and guard-policy commit specifically.
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
- Deployment authority as clarified on 2026-10-06 (preview autonomous under policy; persistent only if pre-authorised; production owner-only).
- The command-token mechanism.
- D1: tokens come from `UserPromptExpansion`, never `UserPromptSubmit`.
- D2: the human-only `/ai-engineering:approve` command exists, and approval stays distinct from delivery authorisation.
- D3: no main-session model requirement.
- D5: the gate-bootstrap PR is merged before this work starts, and CodeRabbit is the external reviewer for this PR.
## Open decisions
- None. D1–D6 are resolved (see `WORK-001-planning.md`).
## Implementation state
<!-- v0.2 deliver records task status and verdict lines here. Keep entries to one line each; put detailed evidence in WORK-002.log.md. -->
-
## Review state
<!-- v0.2 review records its status block here. -->
-
