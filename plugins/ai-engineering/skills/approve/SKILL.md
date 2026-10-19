---
name: approve
description: Record an owner decision on a work item - approve a spec, accept or defer a finding, lower an increment's tier, or revoke approval. Human only.
argument-hint: "<WORK-ID> [spec | accept <finding-id> | defer <finding-id> | tier <increment-id> <0|1|2> | revoke]"
disable-model-invocation: true
---
# Approve work

Record one owner decision through the transition script. Only the owner types this command. Arguments: `$ARGUMENTS`. With no sub-action, use `spec`.

A record made here is a workflow record, not security authority: it does not change any guard decision or permission.

## Run
Map the arguments to exactly one call and run it through Bash. Never put a state file path on the command line; the script derives it from the work ID.
- `<WORK-ID>` or `<WORK-ID> spec`: `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" approve <WORK-ID> spec --owner-command approve`
- `accept` or `defer`: `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" approve <WORK-ID> <accept|defer> <finding-id> --owner-command approve`
- `tier`: `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" approve <WORK-ID> tier <increment-id> <0|1|2> --owner-command approve`
- `revoke`: `"${CLAUDE_PLUGIN_ROOT}/scripts/workstate.sh" approve <WORK-ID> revoke --owner-command approve`

Add `--note "<text>"` when the owner gave a reason, and `--decision <id>` when resolving an open trigger-3 decision. Do not invent a finding, increment or tier: if an argument is missing, ask for it.

## Report
Print the script's output, then say what changed in one line. Map the exit code:
- 0: done. After `spec`, suggest `/ai-engineering:deliver <WORK-ID>`. After `accept`, `defer` or `tier` with `--decision` on a blocked item, suggest `/ai-engineering:deliver <WORK-ID>` to resume it.
- 2: usage error; show the accepted forms above.
- 3: invalid transition (wrong status, unknown record or rule not met); say what status is needed.
- 4: owner command missing; the marker was not accepted.
- 5: the state is missing or corrupt; it is never repaired here. Suggest `/ai-engineering:plan`, or `/ai-engineering:setup` import for a v0.2 item.
- 6: the spec changed since approval; the item is back in `proposed`. Re-read the spec, then approve again.
- 7: delivery policy rejected; show the reasons and ask the owner to fix the spec's Delivery policy section.
- 1 or other: environment error; show the output.

Never claim that this command is a signature, a permission grant or a security control.
