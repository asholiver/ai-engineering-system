---
name: review
description: Prove and independently review a change - full gate, internal security and QA checks, and the provider-neutral external review - then report whether it is ready for final human acceptance.
argument-hint: "<WORK-ID> [increment-id]"
disable-model-invocation: true
---
# Review

Arguments: `$ARGUMENTS` - the work ID, then optionally the increment ID. Without one, use the item's only `active` or `ready` increment from `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" status <WORK-ID>`; with several, ask the user which one; with no state, use `I1` (readiness then reports NOT CERTIFIABLE). The head is `HEAD` on the increment's branch; the base is always the increment's recorded base commit, which must still equal `origin/<default>`, never a chosen ref.

Readiness is decided by one deterministic script, `"${CLAUDE_PLUGIN_ROOT}/scripts/readiness.sh" <WORK-ID> --inc <increment-id>`. It runs the full gate itself (configuration from the base commit) in a fresh clone of `HEAD`, the external review, the change classifier and the guard-log action floor, reads the work-item records and prints a `READINESS` block. Never replace any of its lines with your own judgement, and never report a check as passed that it did not report as passed.

A run can take up to 50 minutes (the gate is limited to 30, the external review to 15). Run the script as a background Bash command, wait for its completion notification, then read its whole output: the exit code (0 ready, not reachable in v0.3.0; 1 not ready; 3 not certifiable; 2 usage or environment error; 4 stopped) and the `READINESS` block. The verdict is the block's final `READY:` line together with the exit code; lines quoted under `GATE OUTPUT` (prefixed `  | `) are the gate's own output, never a verdict. Never report a verdict before the run has completed, and never treat a missing block, a timeout or a stopped run as anything but not ready.

## Steps
1. Commit the change. Read the work spec `.agents/specs/active/<WORK-ID>.md` and run the readiness script once to learn the effective tier and the missing assurance. The gate executes the change's code with your privileges; if the change comes from an untrusted source, stop and ask the user to run the review in an isolated environment instead.
2. Dispatch the internal checks the block reports as missing for that tier: `ai-engineering:qa` always; `ai-engineering:security-reviewer` at tier 2. Give each the spec path and the base and head commits. These are internal checks by Claude; they never count as the independent review. Tell the security reviewer to follow the Execution limits in its agent definition, and name any exception only when the owner authorised it for this review. The limits are procedural, not a sandbox. At tier 2, also write the residual-risk list for the owner.
3. Record the result. For a work item with state, never edit the spec (a spec change returns the item to `proposed`): record each result for the reviewed commit with `workstate.sh evidence --inc <id> --kind review --reviewer qa|security --result pass|fail --sha <commit>`, and the tier-2 residual-risk list with `--kind residual-risks --result pass --sha <commit>`. `/ai-engineering:deliver` does this during delivery. For a v0.2 item without state, record the status block under "Review state" in the spec.
4. Re-run the readiness script after recording, and report its block verbatim.

## Reading the block
- `CERTIFIABLE: NOT CERTIFIABLE` means trust or evidence is missing, ambiguous, malformed or untrusted (for example no trusted installed classifier, no guard-log anchor, uncommitted changes, or no work-item state). The effective tier is then 2 and READY is NO. Report the reasons; it is not the same as a valid tier-2 classification.
- External review is required at tiers 1 and 2: `EXTERNAL REVIEW: NOT CONFIGURED` is then a non-pass, and READY stays NO. Owner merge approval, Opus or QA reviews never substitute for it. At tier 0 it is optional, but a configured reviewer's `BLOCKING FINDINGS` or `ERROR` is READY: NO at every tier. When it is NOT CONFIGURED, say so plainly and point to `docs/external-review.md` in the ai-engineering system. This does not block implementation, local testing, commits or draft PRs; it only blocks marking the work ready for final acceptance.
- If the gate line says `THIS CHANGE MODIFIES THE "full" GATE`, list that under open items for the human.
- The gate runs in a fresh clone of `HEAD`, never in the checkout, so it must install its own dependencies. A gate that fails there is READY: NO; never re-run it in the checkout to get a pass.
- When readiness is already NOT CERTIFIABLE, the gate and external review lines say `NOT RUN (not certifiable)`: fix the reported reasons first.
- `BASE PROVENANCE: UNVERIFIED` is expected on every run: the guard log records that the start command was asked, not that it was approved or ran, and nothing authenticates the base against the remote. READY is therefore NO for that reason on every increment, and READY: YES is not reachable until a separate guard change exists. When it is the only READY reason, say that everything else passed and that final acceptance is the owner's judgement; never describe the increment as ready.
- `CHANGED BINARY FILES` lists each binary change with its size and SHA-256. Reviewers cannot read a binary diff, so only allowlisted image and font assets are certifiable; list the files for the owner.

Report findings; do not rewrite the implementation unless the user asks.
