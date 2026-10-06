# WORK-001 delivery log
Detailed evidence for WORK-001 delivery. The spec's "Implementation state" keeps one-line entries only.

## Guard prompts during delivery (v0.2 governing; v0.2 → v0.3 comparison)
| # | Date | Caller | v0.2 class | Owner decision | Category | Notes |
| :- | :- | :- | :- | :- | :- | :- |
| 1 | 2026-10-06 | T1 backend subagent | infrastructure apply/destroy | Denied | False positive, known category: keyword in data (inert test/fixture content inside a compound Bash command) | Same root cause as the Landra F0 false positives (ADR-0003 Context). Remediation: fixture and benchmark inputs go in files, and each command runs alone with no reserved words in its text. The guard was not weakened or bypassed. Shape, per the agent: a chained command that built hook-JSON fixtures and timed the guard. One inline JSON fixture string contained an infrastructure-apply phrase as sample hook input. |
| 2 | 2026-10-06 | T2 backend subagent | SQL TRUNCATE (destructive SQL) | Denied | False positive, known category: keyword in data (inert source code inside a Python heredoc used to edit a file); distinct from #1 | Matches Landra instance 1/3 (source text written through the shell). The edit through the shell also breached the agent's Edit/Write instruction, which is the behaviour WORK-001's shell-edit hint targets. Remediation: all file changes through Edit/Write, no reserved vocabulary in Bash command lines. The guard was not weakened or bypassed. Per the agent: a Python heredoc rewriting `guard/policy.jq` in place to add the new policy section; inert jq source in the heredoc body was read as destructive SQL. Rewritten with the Write tool instead. The agent also reported that two earlier Python-heredoc edits to `guard/classify.jq`, made before the rule was relayed, went through without a prompt. |

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
| T2 | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (619 passed, 0 failed) |

## Judgement calls for owner acceptance (T2)
- Git write list extended beyond the spec with `pull`, `rm`, `mv`, `clean` (they change the working tree or index); `fetch` stays allowed. `checkout`/`switch` with any argument, including `checkout -b`, are denied to specialists.
- Bash authority-store detection deliberately over-matches: any `*.state.json` path and any path through `ai-engineering/tokens/` is denied, because the parser does not track `cd`. `guard-writes.sh` matches precisely.
- Shell-edit hint: whether Claude Code honours PreToolUse `additionalContext` without a decision is unverified; it needs an end-to-end check in a scratch project (spec: drop the hint if unsupported).
- Residuals not closable in jq: symlinked ancestors in Bash paths, variable/alias/script indirection (including Git aliases), `find -exec`/`-delete`, hint limited to inline code and heredocs.

