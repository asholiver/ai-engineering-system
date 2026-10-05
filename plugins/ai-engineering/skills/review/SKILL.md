---
name: review
description: Prove and independently review a change - full gate, internal security and QA checks, and the provider-neutral external review - then report whether it is ready for final human acceptance.
argument-hint: "<WORK-ID> [base-ref]"
disable-model-invocation: true
---
# Review

Arguments: `$ARGUMENTS` - the work ID, then optionally the base ref (default `main`). The head ref is `HEAD`.

## Steps
1. Read the work spec `.agents/specs/active/<WORK-ID>.md` (if present) and `git diff <base>...HEAD --stat`.
2. Full gate: run `"${CLAUDE_PLUGIN_ROOT}/scripts/run-gate.sh" full` and take its verdict line verbatim.
3. Internal checks: delegate to `ai-engineering:security-reviewer` and `ai-engineering:qa` with the spec path and base ref. These are internal checks by Claude; they never count as the independent review.
4. External independent review: commit the change first. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/external-review.sh" <base> HEAD <spec-path>` and take its final `EXTERNAL REVIEW:` line verbatim. The reviewer command is read from `.agents/gates.json` as committed at the base ref, so a change cannot alter its own reviewer; report any NOTE the script prints. Never substitute a Claude review when it is NOT CONFIGURED or ERROR.
5. Record the status block under "Review state" in the spec.

## Report exactly this block
```
REVIEW STATUS - <WORK-ID> (<base>..HEAD)
<GATE full verdict line from run-gate.sh, verbatim>
SECURITY REVIEW (internal): <no findings | N findings, highest severity>
QA (internal): <criteria met / not met / unverified>
EXTERNAL REVIEW: <PASSED | BLOCKING FINDINGS | ERROR | NOT CONFIGURED>
READY FOR FINAL HUMAN ACCEPTANCE: <YES | NO - reasons>
```
READY is YES only when the full gate passed, there are no unresolved critical or high findings, every acceptance criterion is MET, and EXTERNAL REVIEW is PASSED.

When EXTERNAL REVIEW is NOT CONFIGURED, say so plainly and point to `docs/external-review.md` in the ai-engineering system. This does not block implementation, local testing, commits or draft PRs; it only blocks marking the work ready for final acceptance.

Report findings; do not rewrite the implementation unless the user asks.
