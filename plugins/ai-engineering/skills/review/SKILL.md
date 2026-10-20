---
name: review
description: Prove and independently review a change - full gate, internal security and QA checks, and the provider-neutral external review - then report whether it is ready for final human acceptance.
argument-hint: "<WORK-ID> [increment-id]"
disable-model-invocation: true
---
# Review

Arguments: `$ARGUMENTS` - the work ID, then optionally the increment ID. Without one, use the item's only `active` or `ready` increment from `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" status <WORK-ID>`; with no state or no single such increment, use `I1` (readiness then reports NOT CERTIFIABLE). The head is `HEAD` on the increment's branch; the base is always the merge-base with `origin/<default>`, never a chosen ref.

Readiness is decided by one deterministic script, `"${CLAUDE_PLUGIN_ROOT}/scripts/readiness.sh" <WORK-ID> --inc <increment-id>`. It runs the full gate itself (configuration from the base commit), the external review, the change classifier and the guard-log action floor, reads the work-item records and prints a `READINESS` block. Never replace any of its lines with your own judgement, and never report a check as passed that it did not report as passed.

## Steps
1. Commit the change. Read the work spec `.agents/specs/active/<WORK-ID>.md` and run the readiness script once to learn the effective tier and the missing assurance. The gate executes the change's code with your privileges; if the change comes from an untrusted source, stop and ask the user to run the review in an isolated environment instead.
2. Dispatch the internal checks the block reports as missing for that tier: `ai-engineering:qa` always; `ai-engineering:security-reviewer` at tier 2, or at tier 1 when the classifier flags a security category. Give each the spec path and the base and head commits. These are internal checks by Claude; they never count as the independent review. Tell the security reviewer to follow the Execution limits in its agent definition, and name any exception only when the owner authorised it for this review. The limits are procedural, not a sandbox. At tier 2, also write the residual-risk list for the owner.
3. Record the result. For a work item with state, never edit the spec (a spec change returns the item to `proposed`): record each result for the reviewed commit with `workstate.sh evidence --inc <id> --kind review --reviewer qa|security --result pass|fail --sha <commit>`, and the tier-2 residual-risk list with `--kind residual-risks`. `/ai-engineering:deliver` does this during delivery. For a v0.2 item without state, record the status block under "Review state" in the spec.
4. Re-run the readiness script after recording, and report its block verbatim.

## Reading the block
- `CERTIFIABLE: NOT CERTIFIABLE` means trust or evidence is missing, ambiguous, malformed or untrusted (for example no trusted installed classifier, no guard-log anchor, uncommitted changes, or no work-item state). The effective tier is then 2 and READY is NO. Report the reasons; it is not the same as a valid tier-2 classification.
- External review is required at tiers 1 and 2: `EXTERNAL REVIEW: NOT CONFIGURED` is then a non-pass, and READY stays NO. Owner merge approval, Opus or QA reviews never substitute for it. At tier 0 it is optional. When it is NOT CONFIGURED, say so plainly and point to `docs/external-review.md` in the ai-engineering system. This does not block implementation, local testing, commits or draft PRs; it only blocks marking the work ready for final acceptance.
- If the gate line says `THIS CHANGE MODIFIES THE "full" GATE`, list that under open items for the human.

Report findings; do not rewrite the implementation unless the user asks.
