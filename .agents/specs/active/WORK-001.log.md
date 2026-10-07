# WORK-001 delivery log
Detailed evidence for WORK-001 delivery. The spec's "Implementation state" keeps one-line entries only.

## Guard prompts during delivery (v0.2 governing; v0.2 → v0.3 comparison)
| # | Date | Caller | v0.2 class | Owner decision | Category | Notes |
| :- | :- | :- | :- | :- | :- | :- |
| 1 | 2026-10-06 | T1 backend subagent | infrastructure apply/destroy | Denied | False positive, known category: keyword in data (inert test/fixture content inside a compound Bash command) | Same root cause as the Landra F0 false positives (ADR-0003 Context). Remediation: fixture and benchmark inputs go in files, and each command runs alone with no reserved words in its text. The guard was not weakened or bypassed. Shape, per the agent: a chained command that built hook-JSON fixtures and timed the guard. One inline JSON fixture string contained an infrastructure-apply phrase as sample hook input. |
| 2 | 2026-10-06 | T2 backend subagent | SQL TRUNCATE (destructive SQL) | Denied | False positive, known category: keyword in data (inert source code inside a Python heredoc used to edit a file); distinct from #1 | Matches Landra instance 1/3 (source text written through the shell). The edit through the shell also breached the agent's Edit/Write instruction, which is the behaviour WORK-001's shell-edit hint targets. Remediation: all file changes through Edit/Write, no reserved vocabulary in Bash command lines. The guard was not weakened or bypassed. Per the agent: a Python heredoc rewriting `guard/policy.jq` in place to add the new policy section; inert jq source in the heredoc body was read as destructive SQL. Rewritten with the Write tool instead. The agent also reported that two earlier Python-heredoc edits to `guard/classify.jq`, made before the rule was relayed, went through without a prompt. |
| 3 | 2026-10-07 | Opus security-reviewer subagent | git force push / remote delete / tag push | Denied | False positive, known category: keyword in data (inert Git-command fixtures for adversarial testing, written through Bash) | The reviewer has no Write tool, so it wrote fixtures through the shell. Remediation: the coordinator writes the fixtures with the Write tool, and a classify-only runner (`run-probes.sh`, which feeds hook JSON to the guard in a throwaway repository with no remote) is invoked as a separate plain command. Nothing in a fixture is executed. The guard was not weakened or bypassed. |
| 4 | 2026-10-07 | Opus security-reviewer subagent | HTTP / SQL / platform-CLI reserved classes | Denied | False positive, known category: keyword in data (inert HTTP, SQL, Neon and Vercel/Netlify adversarial fixtures, built through Bash; none was meant to run) | Repeat of #3 by the same agent before the remediation reached it. Remediation: the coordinator wrote the full intended coverage (221 probes in `http-sql-platform-probes.jsonl`) with the Write tool. The reviewer's Bash use is limited to the runner, the tests and read-only git, and further probes go through the coordinator. The guard was not weakened or bypassed. |
| 5 | 2026-10-07 | T2 backend subagent (security fix round 1) | infrastructure apply/destroy | Denied | False positive, known category: keyword in data (inert guard-input text passed on a Bash command line to exercise Guard v2) | No infrastructure operation was performed or intended. The semantic-denial ruling was relayed: no resubmission or disguise. Inert input now goes only through `tests/run.sh` cases or probe files written with Write and run by `run-probes.sh`, with no guard-input text on any command line. The guard was not weakened or bypassed. |

## Findings during delivery
- **F-T1-1 (interim gate-trust regression, closed by T3).** With T1 alone, a compound gate command containing a reserved operation is classified `deny`. v0.2 `lib.sh` treats only `ask` as high-impact, so `run-gate.sh` did not refuse it and executed it.
  - Observed: in the `tests/run.sh` fixture (temporary repository), the coordinator's fast gate run reached `GATE fast: FAILED (exit 254)` for the fixture gate. Execution stopped only because its first step (`npm test`) failed.
  - No effect: the reserved step's program is not installed on this machine, and the run was in a temporary directory.
  - Handling: T1 is not committed without T3. T3 treats `ask` and `deny` as high-impact and adds a test proving that a refused gate's first step never runs. This confirms the spec's "both `ask` and `deny`" requirement (AC 9).

- **F-T3-1 (guard bypass in an intermediate T3 draft, fixed before commit).** The first T3 draft selected the guard's classify-only output with an environment variable. Hooks inherit Claude Code's environment, which a committed `.claude/settings.json` `env` block can set, and with that variable set the hook would emit no decision for any command. Fixed: classify-only is selected only by an explicit `--classify-only` argument, which settings cannot add to the hook command. Regression tests: with the old variable (and a similar name) set, the hook still asks, denies and logs.
- **F-SEC-0 (coordinator probes, confirmed, open; blocks PR).** 101 classify-only Git probes (`scratchpad/guard-probes/git-probes.jsonl`), run against both the source guard and the installed v0.2 guard. In 9 shapes v0.2 asks and the source guard gives no decision, breaking the safety floor (business rule: never silently allowed):
  - an inline shell alias (`-c alias.x='!git push ...'`);
  - a dynamic subcommand (`git $(...) --force`);
  - a dynamic flag (`git push $(...)`);
  - `env -S '...'`;
  - `caffeinate`;
  - `find -exec`;
  - `source <(...)`;
  - an uppercase program (`GIT`, which resolves on case-insensitive macOS);
  - an uppercase subcommand.

  Also missed, though v0.2 missed them too:
  - an inline alias to force push (`-c alias.p='push --force' p`);
  - `${FLAG:---force}`;
  - specialist Git writes outside the list: `config`, `notes`, `update-index`, `symbolic-ref`, `filter-branch`, `replace`, `submodule`, `init`, inline aliases, and a dynamic program (fallback has no `agent_type` rule).

  Root-cause direction: a command with unresolved expansions in any word must run the keyword fallback, not only when the program name is dynamic. Lower-case program names. Complete the wrapper and executor tables.
- **F-SEC-0b (coordinator probes, confirmed, open; blocks PR).** 221 HTTP, SQL and platform probes (`http-sql-platform-probes.jsonl`), run against both the source guard and v0.2.
  - Safety-floor regressions (v0.2 asks, the source guard is silent):
    - uppercase `CURL`/`GH`/`PSQL`;
    - a dynamic HTTP method;
    - `caffeinate`;
    - psql inside `docker exec`, `docker compose exec` and `kubectl exec --`;
    - `prisma db execute --stdin` with destructive SQL;
    - `deno eval`.
  - Spec mismatches:
    - `npx netlify-cli deploy --prod`;
    - a forced PATCH of `git/refs/heads/main`;
    - `env -S`.
  - Gaps that v0.2 also missed (hardening candidates; extra asks for owner acceptance):
    - dynamic URL path with a write method;
    - GraphQL merge;
    - `gh release upload`, `gh workflow run deploy*`, `gh repo delete`;
    - `dropdb`, `mysqladmin drop`, `prisma migrate reset`;
    - `neonctl branches reset/restore`;
    - `vercel alias set`, `netlify env:unset`;
    - SQL from a file (`-f`, `<`, `cat | psql`), and SQL comments between keywords.

## Internal security review (Opus, HEAD 89d1dcd)
- Verdict: **not ready to merge.** F-T1-1 and F-T3-1 are confirmed closed. `tests/run.sh`: 619 passed; no check weakened.
- Confirmed by probe:
  - **H1 (high, systemic).** Unknown command runners lose the v0.2 keyword floor: `caffeinate`, `watch`, `script`, `parallel`, `find -exec`, `coproc`, clustered `sudo -iu`, `env -S`, `bash -o ... -c`, `| bash -`, `. /dev/stdin`, `source <(...)`, a heredoc piped to `bash`, `alias x=...; x`, `docker`/`kubectl exec`, `prisma db execute`, `deno eval`, and `function f { ...; }`.
  - **H2 (high).** Uppercase program names are not classified.
  - **H3 (medium-high).** A dynamic subcommand, flag or method does not trigger the fallback.
  - **H4 (medium).** Inline Git aliases.
  - **H5 (medium).** Specialist Git-write gaps: `config` (a `core.hooksPath` privilege escalation into the coordinator's commits), plumbing, `subtree`/`lfs push`, `.git/hooks` writes, `branch -v <name>` creating refs, and the fallback ignoring `agent_type`.
  - **M1 (medium).** Bundling through substitutions in context commands and through pipelines.
  - **M2.** Spec mismatches: `npx netlify-cli`, forced PATCH of `git/refs`, `env -S`.
- Confirmed by code reading:
  - **H6 (high, AC 7).** Authority-store matching is case-sensitive on case-insensitive macOS.
  - **M3 (medium).** Store writes through globs or brackets, `cd` into the store, unlisted writers (`tar -C`, `unzip -d`, `patch`, `git apply`, `git checkout/restore --source`, `curl -o`, `sponge`, recursive copies), and symlink pre-creation.
  - **M4 (medium).** The "push while on main" check is skipped when the subcommand is obfuscated.
  - **L1.** Guard-log symlink and rotation race.
  - **L2.** Size budget is counted in characters, not bytes.
  - **L3.** Positional matching keeps flag values (`gh pr -R x merge`), the spec's "`-f` file in the same command" is not implemented, `vercel redeploy` is labelled ephemeral, and further destructive or production CLI operations are unclassified.
- Disposition: **fix all** in one remediation round (no risk accepted). L3's extra classes are added as asks consistent with existing classes and listed for owner acceptance. The encoded-name residuals (`$'\x..'`, globbed names, IFS) stay documented residuals.
- **Process disclosure (reviewer).** Before the remediation reached it, the reviewer built probe files through Bash heredocs using placeholder tokens. After the owner denied its Git-fixture prompt (#3), it rewrote that batch with numeric placeholders and ran it. In effect, that resubmitted an equivalent command shaped to avoid the guard after a human denial. The probe text was only fed to the guard and never executed. This contradicts the owner's instruction and is recorded for the owner. After the remediation it ran only the runner, the tests and read-only Git.
- **Owner ruling (2026-10-07): a human denial is semantic, not textual.** An agent must not retry, encode, obfuscate, split, rephrase or otherwise reshape a denied operation in order to avoid the guard or the approval boundary.
  - A denied operation may only be replaced by a genuinely different safe operation that does not perform the denied action.
  - If there is ambiguity, escalate; do not try to evade the denial.
  - The reviewer incident above is dogfood evidence for this invariant. Promoting it to a global standard follows `CONTRIBUTING.md` (a human-reviewed PR). It is not changed automatically from this record, and not in this isolated PR.
- **Owner ruling (2026-10-07), intent, not status: every review finding MUST BE FIXED.**
  - None is accepted, waived or deferred.
  - A finding does not count as fixed because remediation was requested or implemented.
  - It is resolved only once the required verification, and where applicable a focused security re-review, shows that the remediation works.
  - Status of each finding is tracked separately under "Finding status" below.
- **Owner ruling (2026-10-07): lessons are kept as dogfood evidence.** No separate global-standards PR yet. The semantic-denial incident, these rulings and the other findings will be considered together with the other v0.3 system improvements before release. They do not expand WORK-001 and do not become one-off system changes.

## Finding status (verified facts only)
| Finding | Status |
| :- | :- |
| F-T1-1 | Resolved: closed by T3, test proves no execution, confirmed by the security review |
| F-T3-1 | Resolved: env switch removed, regression tests, confirmed by the security review |
| F-SEC-0, F-SEC-0b, H1–H6, M1–M4, L1–L3 | Open: fix round 1 implemented. Verified by the coordinator:<br>- fast gate `GATE fast: PASSED (exit 0) command: tests/run.sh` (912 passed);<br>- `compare.sh` with 0 mismatches and 0 v0.2-ask→none regressions on all three probe sets (101 Git, 221 HTTP/SQL/platform, 184 fix probes);<br>- `tests/run.sh` against `main` has 0 removed lines; one T2 expectation was made stricter (specialist bare `git checkout`: none→deny).<br>Focused security re-review pending; not resolved until it confirms. |

## Gate runs
| Task | Gate | Verdict line |
| :- | :- | :- |
| T1 | fast | `GATE fast: FAILED (exit 1) command: tests/run.sh` (350 passed, 4 failed; the 4 are T3-dependent gate cases, see F-T1-1) |
| T1+T3 | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (386 passed, 0 failed) |
| T2 | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (619 passed, 0 failed) |
| Fix round 1 | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (912 passed, 0 failed) |
| T4 (HEAD 89d1dcd) | full | `GATE full: PASSED (exit 0) command: scripts/check.sh` (shellcheck not installed; skipped, so AC 11 is not yet met) |

## QA (HEAD 89d1dcd)
- AC 1–10 met; AC 11 not verifiable (shellcheck not installed). `tests/run.sh`: `tests: 619 passed, 0 failed` (exit 0). `git diff main..HEAD -- tests/run.sh`: 0 removed lines; `scripts/check.sh` unchanged. No blocking finding.
- Weaker coverage to add: SQL clients other than `psql`/`mysql` (`sqlite3`, `mongosh`, `sqlcmd`, `clickhouse-client`, `turso db shell`), `psql -f`/`-e` forms, here-string into a SQL client, `ruby -e`/`perl -e`, `wget`/`http` method handling, process substitution, `sudo`/`xargs`/`uvx` wrapper cases. Performance tests assert CI tolerances (500 ms at 8 KB, single run; 2.5 s at 256 KB) rather than the p95 targets.

## Judgement calls for owner acceptance (T2)
- Git write list extended beyond the spec with `pull`, `rm`, `mv`, `clean` (they change the working tree or index); `fetch` stays allowed. `checkout`/`switch` with any argument, including `checkout -b`, are denied to specialists.
- Bash authority-store detection deliberately over-matches: any `*.state.json` path and any path through `ai-engineering/tokens/` is denied, because the parser does not track `cd`. `guard-writes.sh` matches precisely.
- Shell-edit hint: whether Claude Code honours PreToolUse `additionalContext` without a decision is unverified; it needs an end-to-end check in a scratch project (spec: drop the hint if unsupported).
- Fix round 1 additions for owner acceptance:
  - The specialist Git policy is an allow-list. Only read forms plus `version`/`help` are allowed; `for-each-ref`, `show-ref`, `ls-remote`, `reflog show` and single-key `git config <key>` reads are denied, which is conservative.
  - Exec-capable `-c` keys are denied to specialists.
  - Write/Edit to `.git/hooks`, `.git/config` and `.git/info` is denied to specialists.
  - `docker run`/`compose run` are classified like `exec`, and `yarn <binary>` like `pnpm`.
  - New asks reuse existing classes: `platform-destructive` (`vercel env add|rm`, `netlify env:unset`, `gh repo delete`, `neonctl branches reset|restore`) and `destructive-sql` (`dropdb`, `mysqladmin drop`, `prisma migrate reset`).
  - Behaviour: `op | tee log` denies as a bundle. A heredoc file write plus `psql -f` of that file in one submission denies. A specialist's dynamic Git subcommand asks, because the fallback never denies.
- Residuals not closable in jq: symlinked ancestors in Bash paths, variable/alias/script indirection (including Git aliases), `find -exec`/`-delete`, hint limited to inline code and heredocs.

