# WORK-002 log
Append-only delivery narrative, written by the coordinator. Not sent to specialists.

## 2026-10-19: delivery authorised and started
- Owner authorisation (conversation, 2026-10-19): "As owner, I authorise delivery of WORK-002 under the accepted Path B amendments merged through PR #8. Implement the v0.3.0 lifecycle scope, including the interim owner-command mechanism, strictly within the amended WORK-002 specification and ADR-0004." Mandatory boundaries: owner commands are workflow coordination only, not security authority; no new guard permissions or changes to protected-operation decisions; no autonomous deployment or bypass of owner confirmation; no signed production approvals (WORK-004); G1 stays OPEN; no assurance below the classifier's minimum tier without the deferred signed-approval mechanism. Merge and deployment need explicit owner approval.
- Base: `main` at `f71b540` (PR #8 Path B merged as `164d821`; PR #9 WORK-003 C1 merged as `f71b540`).
- Gates (`.agents/gates.json`): fast `tests/run.sh`, full `scripts/check.sh`; external review CodeRabbit on the PR (D5).
- Playbook: feature; Opus security review required. Execution: v0.2 deliver, sequential in the main checkout.
- Known constraint (raised to the owner): WORK-001's guard asks on `git merge`, branch switches and similar state-replacing Git commands from every caller, and this spec forbids guard changes. Parallel worktree merges and per-increment branch switches in the rewritten `/deliver` therefore ask in v0.3.0.

## 2026-10-19: B1 state model and transition script
- Backend specialist delivered `plugins/ai-engineering/scripts/workstate.sh` and a "WORK-002 B1: workstate.sh" section in `tests/run.sh` (about 330 assertions). Exit codes: 0 ok, 1 environment, 2 usage, 3 invalid transition, 4 missing/wrong owner command, 5 schema, 6 spec-hash mismatch, 7 policy rejected, 8 import refused.
- Guard parity: `vercel deploy`, `vercel --prod`, `git push origin main`, `gh pr merge`, `npm publish` give identical guard output (ask) with no, honest and forged state. Normal `workstate.sh` command lines get no guard decision.
- Coordinator decisions (not triggers; spec silent, inside intent): conversation answers resolve triggers 1, 2, 4 and 5 (a trigger-4 answer cannot bypass the guard prompt, which still asks); trigger 3 needs an `approve` sub-action. Blocked → delivering is `answer`, no third owner command. `openPullRequest` defaults to ready PRs (CodeRabbit does not auto-review drafts). Increments are added only in `proposed` (scope change otherwise). Imported increments without a tier default to tier 2.
- Coordinator ran the fast gate: `GATE fast: PASSED (exit 0) command: tests/run.sh` (3069 passed, 0 failed).

## 2026-10-19: owner decision on guard confirmations during delivery
- Owner decision (conversation, 2026-10-19), verbatim: "As owner, I approve option 1 for WORK-002 B2: /deliver runs sequentially by default. Parallel worktrees are opt-in. One Guard confirmation is requested when each increment starts. Amend WORK-002 AC9 and Scope item 8 narrowly to reflect this behaviour. This increment-start confirmation must not replace, suppress or pre-authorise any separate Guard prompt for deploy, merge, publish, protected pushes or other reserved operations. The interim owner-command mechanism remains workflow coordination only, not security authority. G1 stays OPEN, and WORK-004 remains responsible for signed approvals and autonomous deployment."
- Spec amended: Scope item 8, AC9 and the settled decision on parallel worktrees. No guard change.
- B2a (approve, deliver entry, plan, setup, banner, agent wording, wait helper) dispatched before the decision because it does not depend on it; B2b (rest of the `/deliver` rewrite) follows.

## 2026-10-19: B2a commands, templates and helpers
- Backend specialist delivered: `skills/approve/SKILL.md` (human-only), the `/deliver` entry transition, the `/plan` template (Increments, Delivery policy, Owner actions; legacy state sections dropped), `/setup` (`worktree.baseRef: "head"`, v0.2 import, worktree question removed), the version and root banner in `inject-standards.sh`, agent wording (no Git writes, trigger-tagged questions, no log or legacy sections), and `wait-github.sh` with a fake-`gh` test matrix.
- Coordinator fix round 1: a file-wide `shellcheck disable=SC2016` in `tests/run.sh` replaced with three line-scoped directives (a file-wide disable weakens the suite's linting).
- Process deviation: the specialist applied part of that fix with a small scripted text edit instead of Edit only. The coordinator checked the resulting `tests/run.sh` diff against HEAD: 169 lines added, none removed, only line-scoped disables.
- Coordinator decisions (inside intent): `wait-github.sh` treats all-digit targets of up to 6 characters as PR numbers and 7–40 hex characters as SHAs; `/plan` adds increments only while `proposed` and otherwise relies on the spec-hash revert.
- Coordinator ran the full gate: `GATE full: PASSED (exit 0) command: scripts/check.sh` (3160 passed, 0 failed; always loaded 6474 of 7000 bytes).
