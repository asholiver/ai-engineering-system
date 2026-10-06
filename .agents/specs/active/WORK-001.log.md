# WORK-001 delivery log
Detailed evidence for WORK-001 delivery. The spec's "Implementation state" keeps one-line entries only.

## Guard prompts during delivery (v0.2 governing; v0.2 → v0.3 comparison)
| # | Date | Caller | v0.2 class | Owner decision | Category | Notes |
| :- | :- | :- | :- | :- | :- | :- |
| 1 | 2026-10-06 | T1 backend subagent | infrastructure apply/destroy | Denied | False positive, known category: keyword in data (inert test/fixture content inside a compound Bash command) | Same root cause as the Landra F0 false positives (ADR-0003 Context). Remediation: fixture and benchmark inputs go in files, and each command runs alone with no reserved words in its text. The guard was not weakened or bypassed. Shape, per the agent: a chained command that built hook-JSON fixtures and timed the guard. One inline JSON fixture string contained an infrastructure-apply phrase as sample hook input. |

## Findings during delivery
- **F-T1-1 (interim gate-trust regression, closed by T3).** With T1 alone, a compound gate command containing a reserved operation is classified `deny`. v0.2 `lib.sh` treats only `ask` as high-impact, so `run-gate.sh` did not refuse it and executed it.
  - Observed: in the `tests/run.sh` fixture (temporary repository), the coordinator's fast gate run reached `GATE fast: FAILED (exit 254)` for the fixture gate. Execution stopped only because its first step (`npm test`) failed.
  - No effect: the reserved step's program is not installed on this machine, and the run was in a temporary directory.
  - Handling: T1 is not committed without T3. T3 treats `ask` and `deny` as high-impact and adds a test proving that a refused gate's first step never runs. This confirms the spec's "both `ask` and `deny`" requirement (AC 9).

- **F-T3-1 (guard bypass in an intermediate T3 draft, fixed before commit).** The first T3 draft selected the guard's classify-only output with an environment variable. Hooks inherit Claude Code's environment, which a committed `.claude/settings.json` `env` block can set, and with that variable set the hook would emit no decision for any command. Fixed: classify-only is selected only by an explicit `--classify-only` argument, which settings cannot add to the hook command. Regression tests: with the old variable (and a similar name) set, the hook still asks, denies and logs.

## Gate runs
| Task | Gate | Verdict line |
| :- | :- | :- |
| T1 | fast | `GATE fast: FAILED (exit 1) command: tests/run.sh` (350 passed, 4 failed; the 4 are T3-dependent gate cases, see F-T1-1) |
| T1+T3 | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (386 passed, 0 failed) |

