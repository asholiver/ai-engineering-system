---
name: deliver
description: Deliver an approved work spec - plan tasks, delegate to specialist agents, run quality gates, escalate failures and stop at human decision points.
argument-hint: "<WORK-ID>"
disable-model-invocation: true
---
# Deliver approved work

Coordinate approved work efficiently. You are the coordinator, not the architecture owner.

## Preconditions
- Read `.agents/specs/active/$ARGUMENTS.md`. If it is missing, not `Approved`, or has NEEDS_HUMAN_DECISION items, stop and say what is needed.
- Read `.agents/gates.json`. If `fast` or `full` is missing, say so; gates that are not configured are reported as NOT CONFIGURED, never as passed.
- Pick the matching playbook from the `playbooks` skill.

## Plan tasks
- Split the spec into tasks with owner (`ai-engineering:frontend`, `ai-engineering:backend`, `ai-engineering:platform`), dependencies, files in scope and acceptance criteria. Decide obvious routing by file area, not by deliberation.
- Record the task list under "Implementation state" in the spec.
- If tasks start to touch shared architectural areas (models, APIs, auth, infrastructure) beyond the spec, stop and return to planning.

## Delegate
- Give each agent only: the spec path, its task, acceptance criteria and files in scope. Do not resend conversation history.
- Run tasks sequentially in the current checkout by default.
- Run independent tasks in parallel only when their files do not overlap and the project's `.claude/settings.json` sets `worktree.baseRef` to `"head"`; otherwise run them sequentially. Claude Code's default worktree base is the remote default branch, which would not contain the work branch. Commit the work branch before dispatching, because worktrees contain committed state only and no gitignored files (dependencies may need installing; see `.worktreeinclude`). Pass `isolation: "worktree"` for those agents, then merge their branches into the work branch and re-run the fast gate.
- Each implementation agent's fast gate runs automatically when it finishes and is silent when it passes: an agent that returns without `GATE FAILED` passed it, unless `fast` is not configured. A report ending `GATE FAILED` means its bounded fix attempts are exhausted: retry once with `model: "opus"` if the cause looks like reasoning difficulty, otherwise stop and escalate to the user with the failure.
- Any open decision an agent reports goes to the user; do not decide it yourself.

## Prove
- Run the full gate: `"${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh" full` and report its verdict line verbatim.
- Delegate to `ai-engineering:qa` with the spec path. Delegate to `ai-engineering:security-reviewer` when the change touches authentication, authorization, input handling, secrets, dependencies, IAM or infrastructure exposure.
- Update "Implementation state" with results.

## Boundaries
- Never run high-impact operations (apply/destroy, deploy, force push, push to main, PR merge, release, publish); the guard hook will ask the human, and you should not try to work around it.
- Normal commits and draft PRs are fine when the user asked for them.

Finish with a short status: tasks done, gate verdicts, QA and security results, open items. Then suggest `/ai-engineering:review $ARGUMENTS`.
