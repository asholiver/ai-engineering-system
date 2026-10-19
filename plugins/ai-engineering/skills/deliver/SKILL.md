---
name: deliver
description: Deliver an approved work spec - plan tasks, delegate to specialist agents, run quality gates, escalate failures and stop at human decision points.
argument-hint: "<WORK-ID>"
disable-model-invocation: true
---
# Deliver approved work

Coordinate approved work efficiently. You are the coordinator, not the architecture owner. State records below use `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" <command> $ARGUMENTS ...` (shown as `workstate.sh`); never put a state file path on a command line. Owner-command records are workflow records, not security authority: no guard reads them, and every protected operation still asks.

## Entry and preconditions
- First action: run `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" deliver $ARGUMENTS --owner-command deliver`. It authorises an approved item and starts delivery, or resumes a paused one. If it exits non-zero, stop and report its message: exit 3 means the item is not approved (or not paused), exit 6 means the spec changed and needs `/ai-engineering:approve` again, exit 5 means there is no usable state. A v0.2 item with no state is refused: point the owner to `/ai-engineering:setup` import, and do not create state yourself.
- Preconditions come from `workstate.sh status` and `show`, not from prose. Open decisions or NEEDS_HUMAN_DECISION items in the spec stop delivery: say what is needed.
- Read `.agents/gates.json`. A gate that is not configured is reported as NOT CONFIGURED, never as passed.
- Print a display-only delivery summary (scope, increments and tiers, delivery policy, planned owner actions). Ask no question about it.

## Execute
- Plan the tasks as a dependency graph by file area, each with owner (`ai-engineering:frontend`, `ai-engineering:backend`, `ai-engineering:platform`), files in scope and acceptance criteria. If tasks start to touch shared architectural areas beyond the spec, that is escalation trigger 1.
- Run tasks sequentially in one checkout by default. Parallel worktrees are opt-in: use them only when the owner asked for them, the tasks' files do not overlap and the project's `.claude/settings.json` sets `worktree.baseRef` to `"head"`. Commit the work branch before dispatching (worktrees hold committed state only), pass `isolation: "worktree"`, then merge their branches into the work branch and re-run the fast gate.
- Starting an increment from the updated default branch asks one guard confirmation. Start it with exactly `git fetch origin <default>` then `git switch -c <work-branch> origin/<default>`; do not check out, pull or merge the default branch locally, because each of those asks again. With parallel worktrees on, each worktree merge also asks. This confirmation never replaces, suppresses or pre-authorises any other guard prompt (deploy, merge, publish, protected push or other reserved operation); each of those still asks.
- Record increment progress with `workstate.sh increment-set --inc <id> --status <status>` (with `--branch`, `--pr`, `--base-sha`, `--head-sha` as known) and each gate or review result with `workstate.sh evidence --inc <id> --kind gate|review --result pass|fail`.
- After each task, run the fast gate through the Bash tool in the working tree that holds the change: `"${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh" fast <directory>`, and report its verdict line verbatim. On `FAILED`, send the agent the gate output to fix, for at most 2 fix rounds; then retry once with `model: "opus"` if the cause looks like reasoning difficulty, otherwise escalate. An agent report ending `GATE FAILED` means its fix attempts are already exhausted: go straight to that step.

## Git is the coordinator's
You create the work branch, commit, merge worktree branches, push the work branch and open or update the increment PR according to the delivery policy (ready or draft; never merge). Specialists edit files and run tests only. Resolving a merge conflict that needs a decision about intent is trigger 1.

## Handoffs
Give each specialist the task, its acceptance criteria, the files in scope and the relevant spec sections, with the path of the full spec. Never pass the log, the conversation, or a legacy v0.2 "Implementation state" or "Review state" section.

## Remediation
- Fix findings inside intent at any severity, and record each with `workstate.sh finding-fixed --finding <id> --sha <commit>`.
- A non-security finding may be marked invalid with evidence: `workstate.sh finding-invalid --finding <id> --evidence <text>`. A security finding needs the raising reviewer's confirmation (`--confirmed-by`); otherwise it is trigger 3.
- Weakening a test, gate or control to clear a finding is trigger 3.

## Escalation
Interrupt the owner only for these triggers, recorded with `workstate.sh block --trigger <1-5> --question <text> --options <a,b>`, stating the options and your recommendation:
1. intent or scope change;
2. an owner-level trade-off: security, product, UX, performance or cost compromise, new dependency, or new external service, account or credential;
3. accepting, waiving, deferring or downgrading risk, or disputing a security finding;
4. a reserved operation (every deploy and other protected operation still asks);
5. an ambiguity whose readings build different things.

Specialists tag open questions with a proposed trigger. Resolve any that is not a trigger yourself and note the reasoning in the log. Do not decide a trigger yourself.

## Decisions
- An answer that chooses among options inside approved intent (triggers 1, 2 and 5, no scope added) may be given in conversation. Record it verbatim with `workstate.sh answer --decision <id> --answer <text>` (source `conversation`), or `workstate.sh decision --trigger <n> --question <text> --answer <text>` when nothing was blocked.
- Accepting risk, lowering a tier and adding scope need `/ai-engineering:approve`. A trigger-3 block resumes only after the owner has answered through `approve ... --decision <id>`. Tell the owner the command; do not record it for them.

## End of each increment
1. Run the `review` skill procedure, the single home of review. Remediate as above, record the result as evidence, and re-run until clean or escalated.
2. Write the increment's learnings once, collected during the work.
3. Push the work branch and open or update the PR according to policy.
4. Produce a readiness summary listing every fix of HIGH severity or above, and every owner-command decision that accepted, waived or deferred risk or lowered a tier.
5. Wait for the owner's merge as a bounded background command: `"${CLAUDE_PLUGIN_ROOT}/scripts/wait-github.sh" merge <pr-number>` (run in the background). A `TIMEOUT` is recorded as the planned owner action "waiting for owner merge" (`workstate.sh owner-action-add --action-id <id> --description <text>`), not retried in a loop.
6. When it reports `MERGED`, record the increment as merged and continue with the next increment without a prompt (apart from the guard confirmation when it starts).
7. When every increment is merged, run `workstate.sh done`.

## Bounded recovery
- A stalled or failed specialist is re-dispatched once with a fresh brief, recorded with `workstate.sh increment-recovery --inc <id>`. A second failure is escalated.
- External waits (CI checks, merge) use `wait-github.sh`. `NOT AUTHENTICATED` becomes a planned owner action: the owner runs `gh auth login`. Never poll without it, and never read an error payload as data.

## Boundaries
- Never run high-impact operations (apply/destroy, deploy, force push, push to main, PR merge, release, publish); the guard hook will ask the human, and you should not try to work around it.
- No autonomous deployment, signing or merge exists in this procedure.

Finish each increment and the whole delivery with a short status: tasks done, gate verdicts, review result, open items and planned owner actions.
