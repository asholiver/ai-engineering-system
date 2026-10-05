# ADR-0002: Gate execution trust boundary
## Status
Accepted. Amends the automatic fast gate in [ADR-0001](ADR-0001-claude-native-architecture.md).
## Context
An independent security review of v0.2 reported that quality gates run project-defined commands with `bash -c` and can therefore execute arbitrary code from an untrusted change. Verification confirmed two issues and showed the reported framing was too narrow: a trusted command such as `npm test` executes whatever the checkout contains (package scripts, tests, test configuration), so protecting the gate configuration does not protect the host.

- **F1 (high).** The `SubagentStop` hook ran the fast gate automatically. Hooks run outside Claude Code's permission checks, auto-mode classifier and sandbox, so an implementation agent's working tree, including uncommitted edits, was executed unprompted with the user's full privileges, environment and network access. Without the plugin the same code would only run through the Bash tool, where the user's permissions and sandbox apply. The plugin was therefore adding an execution path around the user's chosen boundary.
- **F2 (medium).** Gates were read from `.agents/gates.json` as committed at `HEAD`. Whoever controls `HEAD` (a contributor's branch, or an agent that commits) could define the full gate that certifies their own change, for example `"full": "true"`.

Two properties must be kept apart:
- **Gate verdict integrity:** whether a `PASSED` verdict was produced by a gate the change could not choose. The plugin can protect this.
- **Host execution safety:** whether running the change's code can harm the machine. Any gate, test or build of untrusted code executes it. The plugin cannot provide this.
## Decision
- Project gates run through the Claude Code Bash tool by default. `deliver` runs the fast gate after each implementation agent returns, with a bounded number of fix rounds.
- `gate-fast.sh` does nothing unless `AI_ENGINEERING_HOOK_GATES=1`. The opt-in restores automatic in-agent gating, with the risk of F1, for users whose host is itself isolated or whose code is trusted.
- `run-gate.sh` accepts a config ref. `/ai-engineering:review` reads the full gate from the base ref, never from the change. A change that modifies or adds the gate is reported in the verdict line, and a gate defined only by the change counts as not configured.
- The plugin is documented as not being an isolation boundary. Running untrusted code needs an isolated execution environment with scoped or no host credentials and appropriate network controls.
## Alternatives considered
### Documentation-only remediation
Rejected as the fix: instructions to the model cannot govern a hook, and the model cannot verify that credentials or network access are absent. The documentation is still needed alongside the fix.
### A verifier hook
The hook would check for a passing result recorded against the exact working-tree state instead of executing the gate. It was deferred: the record is forgeable from Bash, and whether a sandboxed Bash command can write it has not been verified.
## Consequences
- By default, implementation agents no longer receive gate failures automatically inside their own run. The main session sends failures back, which costs one extra round trip per failure.
- With the opt-in set, the main session's Bash run of the fast gate duplicates the hook run.
- Running a gate through the Bash tool keeps the user's permission rules and sandbox in the path; it does not make untrusted code safe, and an allow rule or a permissive mode can still run it unprompted.
- The full gate run by `deliver` still reads `HEAD`: it is a working check during implementation, not a certification.
