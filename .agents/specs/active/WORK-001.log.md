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

## Focused security re-review (Opus, 89d1dcd..da81e8b)
- Verdict: **not ready to merge.**
  - Resolved: H2, H3, H4, M2, M4, L1, L2, L3, and H6 for ASCII.
  - Partially resolved: H1, H5, M1, M3.
  - F-SEC-0 and F-SEC-0b: resolved for the listed shapes, but the general floor is broken again by N1–N3.
- New findings, all confirmed by the coordinator (`rereview-probes.jsonl`: 43 of 46 probes mismatch, 19 of them safety-floor regressions where v0.2 asks and the source guard is silent):
  - **N1 (high).** An alias name anywhere in the submission disables classification of that program.
  - **N2 (high).** `git` is treated as inert, but `submodule foreach`, `rebase -x`, `bisect run`, `difftool -x`, `filter-branch`, `grep -O`, `--upload-pack` and `-c core.pager` all execute commands. Restricted agents can still run commands through allowed reads and unlisted `-c` keys.
  - **N3 (high).** Other "inert" programs execute: `awk system()`, `sed e`, `tar --to-command`, `zip -TT`, `xargs sh -c` reading stdin, and `kubectl run --`, `make --eval`, `gcloud ssh --command`.
  - **N4 (medium).** Bundling through the operation's own substitutions, read-only commands with write redirections, Git "read" subcommands that write, and a producer exemption that is too broad.
  - **N5 (medium-high).** Store and `.git` path matching misses globs, braces and `$` targets, `git -C`/`env -C` directory changes, and hard links.
  - **N6 (low).** Log `.1` symlink on rotation; Unicode case folding not verified; repository root as a store ancestor for recursive/extract writers and `git checkout <ref> -- .` (**escalated to the owner**); unknown Git aliases (documented residual).
- Process note: no guard prompt was denied. The reviewer kept reserved vocabulary out of its output after a safety-classifier interruption.
- Fix round 2 (Opus backend, per the deliver skill's retry-with-Opus step, because round 1 introduced new holes) changes the root cause. The v0.2 keyword floor (ask-only) now applies to the whole command text minus a narrow, tested list of proven data spans, instead of only to "unclassified" commands. Classification and policy may raise a decision but never lower it below the floor. Brief: `scratchpad/guard-probes/FIX-BRIEF-2.md`.

## Focused security re-review 2 (Opus, da81e8b..38bfb88)
- Verdict: **not ready to merge.**
  - Resolved: N1 (listed shapes), N4, M1, N6 log rotation. F-T1-1 and F-T3-1 are still closed. The guard never allows. The deferred floor matches the jq rules. 552 existing probes give 0 mismatches, and no check was weakened.
  - Partially resolved: N2 (Git environment variables for restricted agents), N3, N5, N6 Unicode, N6 owner ruling.
  - Not resolved: the H1 and M3 remainders.
- New findings, confirmed by the coordinator (`rereview2-probes.jsonl`: 21 mismatches, 9 of them safety-floor regressions):
  - **NR-1 (high).** The lexer splits words on `\s` (CR, VT, FF, NBSP), but Bash does not, so `a<CR>#` hides the rest of the line as a comment.
  - **NR-2 (medium-high).** Look-alike program names (Kelvin sign, long s) resolve on APFS and are not classified.
  - **NR-3 (high).** Proven data reaches execution through process-substitution shells, `sort --compress-program`, and write-then-run within one submission.
  - **NR-4 (high, AC 7).** `git rm`/`mv` of the store, magic pathspecs, `--pathspec-from-file`, `checkout-index` and index plumbing are not write targets.
  - **NR-5 (low).** Case-sensitive `push` guess (performance only).
  - **H5 remainder.** Git environment variables (`GIT_EXTERNAL_DIFF`, `GIT_CONFIG_*`, `GIT_PAGER`) for restricted agents.
- N6 boundary analysis (owner-requested; owner decision pending):
  - (a) Branch switch, merge, pull, stash, rebase and no-ref whole-tree restores can replace committed or uncommitted state files. Coordinator only, several times per work item. Reviewer recommends asking only when the target ref's state files differ from HEAD (a `git diff --quiet` check at hook time) or the ref is unresolved.
  - (b) `patch`/`git apply`/`git am` from unknown files allow arbitrary tracked-file writes. Low frequency. Reviewer recommends ask, or deny when the store is named.
  - (c) The unresolved-destination ask is the safe rule; narrowing to arbitrary variables is unsafe (`dist/$X` with `X=../..`). Only glob-only components under a literal non-protected subdirectory can safely be exempted.
- Fix round 3 (Opus backend) covers NR-1 to NR-5 and the H5 remainder, and leaves seams for the N6 boundary pending the owner. Brief: `scratchpad/guard-probes/FIX-BRIEF-3.md`.

## Owner rulings (2026-10-07): N6 boundary and performance
- **N6(a): ask if state differs.** Branch switches (`checkout <branch>`, `switch`), merge, pull, rebase, cherry-pick, stash and no-ref whole-tree restores (`checkout -- .`, `restore .`, `reset --hard`).
  - For a literal ref, the guard checks at hook time whether the ref's `.agents/specs` state files differ from HEAD, and whether there are uncommitted state changes the operation would discard.
  - It asks only if they differ, the ref is unresolved, or the command is a pull. Otherwise there is no decision.
  - This applies to every caller. Specialists are already denied Git writes.
- **N6(b): ask if unknown.** `patch`, `git apply` and `git am` ask when the patch input is not text written in the same submission. When the input is known: deny if it touches a store path, otherwise no decision. `--include`, `--exclude` and `--directory` go through the pathspec rule.
- **N6(c): narrow for globs only.** Any variable or substitution destination for a recursive or extract writer still asks. There is no decision only when every unresolved component is a glob under a literal subdirectory that is not the root, `.agents` or `.git`, and there is no `..`.
- **Performance: specification correction by the cost driver (command count), approved by the owner.** Three independent properties, each with a test that validates its own fixture preconditions (size and/or command count):
  1. typical commands, p95 < 150 ms;
  2. linear per-command scaling with an explicit upper bound, set conservatively from measurement with headroom (not chosen just to make the current result pass), with the fixture's command count asserted;
  3. large inert heredoc or data input bounded independently of command count (< 1 s up to 256 KB), with the fixture's byte size asserted.
  
  Reason: the byte-size proxy was invalid. Runtime is driven mainly by command count, and the original "8 KB" fixture was only about 3.5 KB. This is not acceptance of a regression and not a security trade. No size-triggered fallback, and no restructuring of security-sensitive classification for the old criterion unless profiling later finds a simple, maintainable optimisation. The chosen per-command bound and its measurement basis are recorded here once fix round 3 measures them.

## Finding status (verified facts only)
| Finding | Status |
| :- | :- |
| F-T1-1 | Resolved: closed by T3, test proves no execution, confirmed by the security review |
| F-T3-1 | Resolved: env switch removed, regression tests, confirmed by the security review |
| F-SEC-0, F-SEC-0b, H1–H6, M1–M4, L1–L3 | Open: fix round 1 implemented. Verified by the coordinator:<br>- fast gate `GATE fast: PASSED (exit 0) command: tests/run.sh` (912 passed);<br>- `compare.sh` with 0 mismatches and 0 v0.2-ask→none regressions on all three probe sets (101 Git, 221 HTTP/SQL/platform, 184 fix probes);<br>- `tests/run.sh` against `main` has 0 removed lines; one T2 expectation was made stricter (specialist bare `git checkout`: none→deny).<br>Focused re-review done: H2, H3, H4, M2, M4, L1, L2, L3 are **resolved**, and H6 is resolved for ASCII (Unicode folding continues under N6). H1, H5, M1, M3, F-SEC-0 and F-SEC-0b are **open** (partially resolved; fix round 2). |
| N1–N6 (including the owner's N6 ruling), H1/H5/M1/M3 remainders | Open: fix round 2 implemented. Coordinator verification (independent of the agent's report; it was produced while the auto-mode safety classifier was unavailable):<br>- diff limited to the guard scripts, `tests/run.sh`, docs, changelog and log; no protected or system file changed;<br>- the only removed test lines are the 8 KB fixture generator and info line, replaced by a genuine 8159-byte fixture with a size assertion;<br>- the installed v0.2 cache is identical to tag `v0.2.0`, the install record is `b875f32`, and there is no `--plugin-dir`;<br>- `GATE fast: PASSED (exit 0) command: tests/run.sh` (1240 passed);<br>- `compare.sh` gives 0 mismatches and 0 v0.2-ask→none regressions on all four probe sets (552 probes); the probe-file edit changed only the two N6 lines (`any`→`ask`).<br>Focused re-review pending; not resolved until it confirms. |
| Re-review 2 verdicts at 38bfb88 | **Resolved:** N1 (listed shapes), N4, M1, N6 log rotation. **Open:** N2 (restricted-agent Git environment), N3, N5, N6 Unicode, N6 owner ruling (partial), H1, H5, M3 remainders. |
| NR-1 to NR-5, H5 environment, N6(a)(b)(c) rulings | Open: fix round 3 implemented. Coordinator verification:<br>- diff limited to the guard scripts and `tests/run.sh` (plus coordinator docs, spec and log); no protected or system file changed, and `guard-writes.sh` is unchanged;<br>- the only removed test lines are an outdated comment about the old 8 KB target;<br>- the v0.2 cache is identical to `v0.2.0`, the install record is `b875f32`, and there is no `--plugin-dir`;<br>- `GATE fast: PASSED (exit 0) command: tests/run.sh` (1409 passed);<br>- `compare.sh` gives 0 mismatches and 0 v0.2-ask→none regressions on all five probe sets (674 probes);<br>- my 27 original re-review-2 expectations are kept or strengthened (three NR-3c write-then-run cases ask→deny; boundary lines set to the owner's rulings).<br>Focused re-review pending. |
| N6 boundary (a), (b), (c) | Owner ruled 2026-10-07; implemented in fix round 3; verification as above; re-review pending |
| Performance (spec: p95 < 150 ms up to 8 KB) | **Not met**; see "Performance analysis". Not accepted; an owner recommendation is pending. |

## Owner ruling N6 (2026-10-07): ask, narrowly
- Whole-directory restore, recursive copy/synchronisation, archive extraction and equivalent operations are legitimate and are never denied merely for writing broadly.
- When such an operation **can** overwrite or replace a protected authority or repository-control path, it **asks**. Protected targets are:
  - the repository root, where the operation can affect protected descendants;
  - `.agents` and `.agents/specs`;
  - the authority-store files;
  - `.git`.
- **Every caller**, the coordinator included. No weaker path for the coordinator.
- The test is whether the operation **can** affect a protected path, not proof that the source or archive currently contains one. Failing to inspect or resolve the source must never turn a potentially protected overwrite into no decision.
- Narrow:
  - no prompt for ordinary writes that cannot affect protected paths;
  - no blanket deny;
  - checkout/restore of ordinary individual non-protected files stays under the existing policy;
  - a whole-tree or ref restore that can replace protected repository state asks;
  - equivalent recursive and extract operations get equivalent treatment, whichever supported tool performs them.
- Not accepted as residual risk. It is implemented in WORK-001 and included in fix round 2 verification and the next focused re-review. No expansion into WORK-002 and no standards PR in this run.
- **Dogfood lesson (preserve):** authority-store protection must consider the *write effect* of an operation, including writes through ancestor directories, not only literal protected path strings.
- Process note: fix round 2's first run was cut short by a usage limit (HTTP 429) and was resumed from its transcript. Partial work was kept, not discarded.
- Process note (2026-10-07): fix round 3 was also cut short by a usage limit, while it was adding the bounded hook-time Git checks for N6(a). Its partial edits are uncommitted and unverified. Resumption was held while Bash calls returned no pre-execution decision (the tool reported "auto mode classifier gave no verdict"), so that the agent would not run unreviewed again; the round-2 handback had to be audited for that reason. The root cause was not verified. On the owner's instruction, one harmless read-only probe (`pwd`) then received its decision and executed. Round 3 was resumed from the working tree. The partial state at resumption, unverified: `tests/run.sh` gave 1344 passed and 4 failed. The four were the agent's own pre-ruling N6 "seam unchanged" cases, now superseded by the owner's N6(a)/(b) rulings.

## Performance analysis (coordinator, 2026-10-07; genuine 8159-byte fixture of 140 pipelines, 280 commands)
- End to end, 30 runs: committed `da81e8b` p50 167 / p95 182 ms; fix round 2 p50 201 / p95 215 ms. Typical command: p95 54 → 79 ms (within budget). The old "8 KB" fixture was 3.5 KB, which hid that `da81e8b` was already over.
- Stages (p50): jq compile ≈ 48 ms fixed; lexing +14; raw parse +25; per-command classification (`parse_script_in`) +84; floor +4; policy +8; wrapper ≈ 10–15 ms.
- Scaling is linear, ≈ 0.47 ms per command (35/70/140/280 pipelines: 81/113/178/321 ms of jq). There is no quadratic hotspot. Heredoc-heavy text costs almost nothing: a 12.6 KB heredoc command takes 49 ms (compile only).
- jq regex calls cost ≈ 2.5–4 µs each and `IN()` ≈ 2 µs. The per-command cost is spread across many checks, so there is no single hot regex.
- Conclusion: no simple, maintainable optimisation was found. Meeting 150 ms for about 280 dense commands would need restructuring of the security-sensitive per-command analysis. The budget is met up to about 90–100 dense commands (about 5 KB) and for large heredocs.

## Performance after fix round 3 (coordinator, independent measurement)
- The three tests in `tests/run.sh`, each validating its own preconditions:
  - (1) typical command: the fixture is asserted to be 4 commands; p95 of 20 runs, CI tolerance 500 ms against a 150 ms target;
  - (2) scaling: fixtures are asserted to be exactly 141, 281 and 561 commands. The marginal cost per command from 70 to 280 pipelines must be **≤ 1500 µs**. Linearity: the 140→280 marginal must be ≤ 2 × the 70→140 marginal + 200 µs;
  - (3) large inert input: a heredoc fixture asserted at 200 KB–256 KB, 1 s target, 2500 ms CI tolerance.
- Chosen per-command bound: 1500 µs. Measured marginal ≈ 445–480 µs per command, linear (per-pipeline marginal 0.86/0.87/0.91 ms for 35–70/70–140/140–280 pipelines). The bound is about three times the measured value, the same headroom ratio as the existing CI tolerances (500 ms against a 150 ms target). Superlinear growth is caught separately by the linearity assertion.
- Coordinator measurement, 30 runs each:
  - typical command p95: 67 ms at `38bfb88`, 90 ms in round 3 (target < 150 ms);
  - genuine 8159-byte command p95: 215 ms at `38bfb88`, 233 ms in round 3.

  The agent reported 211 ms and 82 ms on its own runs; the discrepancy is recorded. The increase is fixed jq compile time from the added rules (≈ +15–17 ms; an empty command goes from about 50 to 67 ms), not per-command cost. One safe optimisation was taken: `classify_invocation` is skipped for programs no table can match, a set derived from the same tables.
- Under the approved correction the 8 KB byte figure is no longer a criterion; the three properties above are. All three pass.

## Gate runs
| Task | Gate | Verdict line |
| :- | :- | :- |
| T1 | fast | `GATE fast: FAILED (exit 1) command: tests/run.sh` (350 passed, 4 failed; the 4 are T3-dependent gate cases, see F-T1-1) |
| T1+T3 | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (386 passed, 0 failed) |
| T2 | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (619 passed, 0 failed) |
| Fix round 3 (working tree before commit) | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (1409 passed, 0 failed) |
| Fix round 2 (working tree before commit) | fast | `GATE fast: PASSED (exit 0) command: tests/run.sh` (1240 passed, 0 failed) |
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

