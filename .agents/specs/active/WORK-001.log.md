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

## Focused security re-review 3 (Opus, 38bfb88..f1fb238)
- Verdict: **not ready to merge.**
  - Resolved: NR-1, NR-2, NR-3a/b, NR-5, N6 Unicode, the H1 remainder.
  - Partially resolved: NR-3c, NR-4, the H5 remainder, N2, N5, M3, N6(b), N6(c).
  - Not resolved as implemented: N6(a).
  - Held: F-T1-1 and F-T3-1 still closed; the guard never allows; Landra cases give none; no check weakened; the performance tests assert their fixtures; the `classify_invocation` skip is sound.
- New findings:
  - **RR3-1 (HIGH, confirmed by the coordinator with a marker fixture).** The N6(a) hook-time `git status` runs repository-configured programs before any approval and outside the sandbox (the ADR-0002 class): `core.fsmonitor`, the `post-index-change` hook, and a `*.state.json` clean filter. Markers were created for `git stash`, `git reset --hard`, `git restore .` and `git checkout -- .`; the decision was none. It also applies through `GIT_CONFIG_*` in the hook environment (committed settings `env`). It exists only on the unmerged branch.
  - **RR3-2 (HIGH).** The fallback, now trivially reachable through NR-1 (`X=<NBSP>`, CR, CRLF), has no rules for the N6(a)/(b), NR-4 and protected-tree classes, which go from ask to none.
  - **RR3-3 (HIGH).** The restricted-agent fallback treats `stash`, `branch`, `tag`, `worktree`, `remote` and `config` as reads, so a specialist's Git write goes from deny to none. That includes `config core.hooksPath`, which combines with RR3-1.
  - **RR3-4 (medium).** N6(a) value-flag table: cherry-pick/revert `-x`/`-s` and checkout/switch/rebase `-m` eat the ref.
  - **RR3-5 (medium).** Tag-versus-branch resolution; control characters in a ref.
  - **RR3-6 (medium).** Stale checks after non-Git ref writes or unknown programs; checks run in the session cwd, not the command's directory.
  - **RR3-7 (medium).** State coverage limited to tracked `*.state.json`; untracked or ignored state, `stash -u/-a` and no-path `clean`; whether state files are tracked, untracked or ignored is undocumented.
  - **RR3-8 (medium).** `~`, `~+`, `cd -`, bare `cd` and `popd` are mis-resolved; N6(c) narrows tilde globs.
  - **RR3-9 (low-medium).** Patch paths: C-style escapes, context-diff `***` headers, `patch -r`.
  - **RR3-10 (medium).** Unlisted store writers: `yq -i`, `sort -o`, `uniq`, `xxd -r`, `ed`.
  - **RR3-11 (low).** Git environment exports through `eval` or a sourced file.
  - **RR3-12 (low).** Write-then-run keys are case-sensitive, and an overwritten known file is still trusted.
  - **RR3-13 (low).** The worst-case hook time (about 54 s) approaches Claude Code's 60 s hook timeout, which means no decision.
- Coordinator confirmation: `rereview3-probes.jsonl` gives 35 of 36 mismatches (the control-character case already asks). None is a v0.2 floor regression, because v0.2 is silent too. RR3-1 is confirmed with `scratchpad/rr3-1/check-hook-exec.sh`.

## Owner rulings (2026-10-07): RR3-1 and RR3-3
- **RR3-1: hardened plumbing only.** The N6(a) ruling ("ask only if state differs") and its low prompt rate stay.
  - Hook-time Git is limited to plumbing that never runs filters, hooks, fsmonitor or external diff.
  - All `GIT_*` variables are cleared, and dangerous configuration is forced off with `-c`.
  - Every hook-time Git call (`rev-parse` and `ls-files` included) is hardened the same way.
  - Proven by marker regression tests, including `GIT_CONFIG_*` in the hook environment. Any failure asks.
  - Lesson (dogfood evidence): any information a guard gathers at hook time must be gathered without executing repository- or environment-controlled code; ADR-0002's boundary applies to the guard itself, not only to gates.
- RR3-1 constraints (owner's full ruling):
  - It is an architectural trust-boundary finding, not a blacklist case. A small, explicitly enumerated hardened-plumbing interface, whose safety property is that repository-controlled executable extension points cannot run.
  - Inherited Git environment cleared, `GIT_CONFIG_*` included; extension points disabled; minimum plumbing; no porcelain.
  - The same hardening for every hook-time Git invocation.
  - Failure, ambiguity, unsupported state, or inability to establish non-execution asks, never none.
  - No general safe-Git abstraction. Adversarial tests for fsmonitor, hooks, filters, textconv/external diff and injected configuration. The marker exploit is rerun independently before RR3-1 counts as fixed.
  - **Stop condition:** if re-review shows the hardened plumbing can still execute repository-controlled code, do not add exceptions or another layer. Escalate for an architectural decision. The safer fallback is to remove hook-time Git inspection and accept the extra asks.
- **RR3-3: keep deny in fallback** for a git-restricted specialist when the fallback positively identifies a Git write, including non-read forms of `stash`/`branch`/`tag`/`worktree`/`remote`/`config`. If the fallback cannot positively establish it, ask. Other fallback matches, including authority-store mentions, ask unless an independently valid deny rule applies.
  - Distinction, documented: "unparseable ⇒ deny" is forbidden; "unparseable + an independently established prohibited operation ⇒ deny" is allowed.
  - Regression tests cover CR, NBSP and the other fallback entry paths: no degradation from deny, and no false deny on ambiguous input.
  - **General invariant:** degraded parsing may reduce certainty, but must not erase independently established security facts.
- **Process rulings for this round:**
  - Verification sequence: diff and test integrity, governing-install provenance, gates, the full probe corpus, the RR3-1 marker exploit, the performance tests with their preconditions, commit, then focused re-review of the exact head.
  - **Stop condition:** if the next review finds another HIGH that is a new general bypass mechanism in the parsing or trust architecture, stop before another broad remediation round and escalate for architectural assessment.
  - These rulings do not authorise a broader scope change or a weakening of existing controls.

## Fix round 4 process notes
- 2026-10-07/08: round 4 was stopped by a usage limit (HTTP 429) near the end; it was starting its extended RR3-1 exploit tests. Under the bounded recovery policy it was resumed once from the working tree. All partial work is unverified.
- Gate-script change in round 4: `scripts/check.sh` adds `scripts/guard/*.sh` (the new hardened Git helper) to the `bash -n` and shellcheck globs. It strengthens the check and removes nothing. Flagged for re-review and CodeRabbit under the spec's "Gate scripts" rule.
- 2026-10-12: the second resumption was also stopped by the weekly usage limit. A new session recovered from the working tree; no agent was relaunched. Round 4's working tree was found complete (tests for RR3-1 to RR3-13 present, gates green) and was verified by the coordinator as below.

## Fix round 4 coordinator verification (2026-10-12, recovery session)
- **Diff and test integrity:**
  - changed files are the guard scripts (new: `guard/hook-git.sh`, `guard/fallback.jq`), `scripts/check.sh` (glob extension only), `tests/run.sh`, docs, changelog and log; no hook registration, agent, settings or protected file changed;
  - `tests/run.sh`: 518 added and 0 removed against f1fb238, and 2195 added and 0 removed against `v0.2.0`, so every v0.2 case and every earlier-round case is kept with its expectation.
- **Governing install:** the v0.2.0 cache is identical to tag `v0.2.0` (`git archive` and `diff -r`; the only extra is the runtime `.in_use` marker), the install record for this project is `b875f32` (= `v0.2.0`), and there is no `--plugin-dir`.
- **Gates:** `tests/run.sh` exit 0 with 1756 passed and 0 failed; `scripts/check.sh` gave `CHECK: PASSED` (exit 0).
- **Performance (corrected spec):** the fixture preconditions are asserted (8159 bytes; 141/281/561 commands). Measured: 148/211/346 ms, a marginal 471 µs per command (bound 1500 µs); the 250 KB heredoc took 150 ms.
- **RR3-1, independent marker exploit** (coordinator-written; not derived from `tests/run.sh`):
  - Hostile repository: fsmonitor; 10 hooks in `.git/hooks` and in `core.hooksPath`; clean/smudge, `process` filter, textconv and `diff.<driver>.command` on `.json`/`.txt`; `diff.external`; `core.sshCommand`, `alternateRefsCommand`, `gpg.program`, `core.pager` and `askPass`; an `ext::` promisor remote; the untracked cache; `include.path` re-enabling fsmonitor. Tracked files are stat-dirty, and there is an untracked state file.
  - Precondition: porcelain `git status`/`git diff` on a copy fired clean, fsmonitor and procfilter.
  - 18 Git commands (stash, reset, restore, checkout, switch, cherry-pick, revert, merge, rebase, clean …) × coordinator and backend × 6 hook environments (plain, `GIT_CONFIG_COUNT`, `GIT_CONFIG_PARAMETERS`, `GIT_EXTERNAL_DIFF`/`GIT_SSH_COMMAND`/`GIT_PAGER`, `GIT_DIR`, `GIT_CONFIG_GLOBAL`), plus `guard-writes.sh` and a direct call of every `hook_git_*` function.
  - Result: **no marker in any run**.
    - With content-identical state, 8 coordinator results were `none`. These are the N6(a) ruling ("ask only if state differs"), not a failure.
    - With modified state, the same matrix gave 0 `none`/`allow` results for state-changing commands, and still no marker.
  - Script: `scratchpad/rr3-1/exploit.sh` (session-scoped; not preserved).
- **v0.2 floor: what the evidence covers.**
  - Demonstrably preserved: every v0.2.0 test case (0 removed lines, all passing).
  - Additionally tested: the round-4 cases for RR3-1 to RR3-13.
  - **Not reconstructable:** the historical probe sets (674 probes and the 36 re-review-3 probes) and `compare.sh` were in a previous session's scratchpad, which has been wiped.
  - Partial substitute: the 1145 distinct commands from the `tests/run.sh` tables, run through the v0.2.0 cache guard and the working-tree guard in one feature-branch fixture (coordinator and backend). This gave 33 coordinator and 30 backend v0.2 ask → none, all of them commands that the suite exercises and passes. The ones listed are proven-data or out-of-scope shapes (Landra instances, GET release URLs, `echo`/`grep` text, push to a non-default branch). Each one's expected value was not individually re-read (see the dogfood note).
  - The historical probe coverage is an open evidence gap, not claimed.
- **Dogfood observation (2026-10-12):** a read-only `grep -nF` over `tests/run.sh`, with literal reserved-keyword phrases as patterns, was rejected before execution. The root cause was not verified (guard hook, classifier or user rejection). Per the owner, it was not retried or rephrased; inspection continued with the Read tool.
- **Dogfood observation (2026-10-12, re-review 4):** a combined commit-amend-and-push command was rejected before execution; per the owner, the commit was not amended and the push was left to a separate owner decision. During the focused re-review, the security reviewer's Bash probe of a write-then-run command shape was rejected before execution by the governing v0.2 tooling. The root cause was not verified. Per the owner, it was not retried or rephrased. The reviewer was told to continue with inert hook-JSON fixture files (written with Write, fed to the guard by path). The denial is not a Guard v2 finding unless it is reproduced through that interface.
- **Dogfood observation (2026-10-12, Option B round):** a Bash call that ran an inline Python heredoc to rewrite `guard/main.jq` was rejected before execution. Afterwards, `git status` showed no source change. Per the owner, it was not retried; the edits were made with the Edit tool. A Bash call that wrote and opened a temporary text copy of a report was also rejected. The root cause was not verified for either.

## Focused security re-review 4 (Opus, f1fb238..2d5a295)
- Verdict: **not ready to close.** There is no new HIGH general parsing bypass.
  - Resolved and independently verified: RR3-2, RR3-3, RR3-5, RR3-6, RR3-7, RR3-8, RR3-10, RR3-11.
  - Partial: RR3-1 (NF-1, NF-3), RR3-4 (NF-2), RR3-9 (C-style escapes checked in tests only), N6(a) (NF-2), N6(b)/(c).
  - Implemented, not independently verified: RR3-12 (the reviewer's probe was rejected), RR3-13 (not re-measured), NR-3c, NR-4, H5, N2, N5, M3 (beyond the fallback probes).
  - Test integrity: `tests/run.sh` +518/−0; `check.sh` glob extension only.
- New findings:
  - **NF-1 (MEDIUM; HIGH on affected Git versions).** The lazy-fetch block in `hook-git.sh` depends solely on `GIT_NO_LAZY_FETCH=1`.
    - The comment's claim that "`protocol.allow=never` means no transport" is wrong: repository `protocol.ext.allow=always` overrides it.
    - Coordinator reproduction (`scratchpad/nf1/repro2.sh`): a `--filter=tree:0 --no-checkout` partial clone, an `ext::` remote that touches a marker, the hook's exact `env -i git … diff-tree` line.
      - With `GIT_NO_LAZY_FETCH=1`: exit 128, no marker, on Homebrew git 2.46.0 and Apple git 2.39.5.
      - Without it: **marker created** on both.
    - So on a Git that ignores `GIT_NO_LAZY_FETCH`, hook-time Git executes repository-controlled code. That was not tested on such a binary; it is the demonstrated mechanism. Both Git binaries on this machine honour the variable.
    - This meets the owner's RR3-1 stop condition, conditionally on the Git version, so it is escalated, not fixed.
  - **NF-2 (MEDIUM, bounded).** A bare `-` (the previous branch) skips the N6(a) state check. For example, `git checkout -` gives none and changes the state file. Not a regression from f1fb238.
  - **NF-3 (MEDIUM, regression from f1fb238/v0.2 in environmental edge cases).** A failed hook-git branch lookup gives none for a bare `git push` on main. Reproduced with `TMPDIR=/nonexistent`, and with a hook-environment `GIT_DIR` from a non-repository cwd. The same pattern applies to the common-directory, root and `guard-writes.sh` lookups.
  - Low: in the fallback, `env`/`command`/`time git commit` from a restricted agent asks rather than denies. This is within the RR3-3 ruling.
- The reviewer's second hand-back agrees: NF-2/NF-3 are reported as F4-1/F4-2, and F4-1 adds `merge -` and `rebase -`.
- Evidence gap: the reviewer has no Write tool, so the inert-fixture probes for RR3-12 could not be built. RR3-12 rests on the code and `tests/run.sh:2201-2214` only.
- Status: remediation stopped under the RR3-1 stop condition; on 2026-10-12 the owner chose Option B (see below). NF-1, NF-2 and NF-3 are implemented and stay open until the focused re-review of the Option B commit.

## Owner decision (2026-10-12): Option B, remove hook-time Git state inspection
- An explicit architectural decision under the RR3-1 stop condition. It is not a weakening of the core guarantees: positively identified prohibited operations still deny, and failures still ask.
- Implementation (fix round 5, bounded):
  - `guard/hook-git.sh` keeps only `rev-parse` discovery (`--git-common-dir`, `--show-toplevel`, `--show-cdup`, `--abbrev-ref HEAD`) and `ls-files` of one path. Every object, tree and ref read is removed (`resolve_commit`, `matching_refs`, `diff-tree`, `diff-index`, `ls-files -s`/`--others`, `hash-object`). The false `protocol.allow=never` claim is corrected.
  - `guard-bash.sh`: the state-check machinery is deleted (`state_can_change` and its helpers, about 160 lines).
  - `policy.jq` `git_state_policy` is now a list of state-changing Git forms, each of which asks with the reason "the guard does not inspect Git state". The pull, checkout, switch, merge, rebase, cherry-pick, revert, stash, restore and `reset --hard` forms are kept as they were, except for the changes below.
  - NF-2: a bare `-` is treated as the operand `@{-1}`. `checkout … -- <paths>` asks when the paths can reach a protected path, whatever ref precedes them.
  - NF-3:
    - A branch, root or common-directory lookup asks when no other decision applies if it fails inside a Git work tree (a `.git` entry in the cwd or an ancestor, found without running Git) or if `hook_git_environment_overrides` is true.
    - `guard-writes.sh` asks on the same condition for the token-store-like path and the hard-link check. Its deny checks run first, so a deny is never lowered.
- Tests:
  - 52 table expectations go none → ask, plus the guard-writes token path under injected configuration (none → ask). Each is commented in place with the reason.
  - The state-comparison reason assertions are replaced by operation-name assertions.
  - The RR3-13 hanging-Git test now reaches the lookup through a bare `git push`.
  - New:
    - NF-1: a partial clone with an `ext::` promisor and `protocol.ext.allow=always`. The precondition asserts it fetches lazily, and a shim drops `GIT_NO_LAZY_FETCH`. The tests assert no fetch, and that every hook-time Git call is `rev-parse` or `ls-files`.
    - NF-2: 12 cases.
    - NF-3: a failing-Git shim, unwritable TMPDIR, `GIT_DIR` in the hook environment, and guard-writes asks. They also check that deny is never lowered and that there is no ask outside a work tree.
  - No ask or deny expectation was removed.
- Verification (coordinator, 2026-10-12):
  - `tests/run.sh`: 1823 passed, 0 failed.
  - `scripts/check.sh`: `CHECK: PASSED`. **shellcheck is not installed on this machine and was skipped**, here and in the round-4 run; `bash -n` ran.
  - Performance: 485 µs per command, unchanged.
  - The independent marker exploit (`scratchpad/rr3-1/exploit.sh`): 0 failures and no marker; every state-changing command now asks.
- **Prompt trade-off (measured).**
  - The 1165 distinct commands in the test tables were run through `2d5a295` and through Option B, as coordinator and as backend.
  - 31 coordinator commands changed from none to ask; there were no other changes (no ask/deny → none, no specialist change).
  - The new asks: `git checkout <branch>`/`git switch <branch>` (and `-`); `git checkout <file>` without `--` (a single operand may be a branch); `git merge`, `rebase`, `cherry-pick` and `revert`, including `--abort`/`--continue`; `git stash` push, pop and apply; `git reset --hard`; `git restore .` and `git checkout -- .`; `git checkout -f`.
  - Still no decision: `checkout -b`/`switch -c` from HEAD, path restores that cannot reach a protected path (`git restore src/x`, `git checkout -- src/x`), `reset` without `--hard`, `stash list`/`show`, and all read forms.
  - Real-world frequency is not measured here. The guard log's `protected-tree-overwrite` entries will measure it; a possible future improvement is a hook-time check that needs no object reads.
- Evidence gaps (unchanged):
  - The historical probe corpus is not reconstructed.
  - RR3-12 is not independently probed.
  - shellcheck has not run.

## Focused security re-review 5 (Opus, 2d5a295..8a037c5)
- **Evidence basis: static only.**
  - The reviewer's one dynamic probe was denied before execution and was not retried, so it counts as not run. The script it would have run was `scratchpad/r5/probe.sh`: it pipes hook JSON to `guard-bash.sh --classify-only` and never runs the supplied Git commands. The denial cause was not verified (dogfood).
  - The verdicts rest on code reading, existing `tests/run.sh` cases and the coordinator's evidence.
- Verdict: **not ready to close.** There is no new HIGH general parsing or trust bypass.
  - NF-1: PARTIAL (F5-3). NF-2: PARTIAL (F5-1). NF-3: PARTIAL (`guard-bash.sh` resolved, `guard-writes.sh` open: F5-2).
  - Option B requirements: 1, 3, 6 and 7 resolved; 2, 4 and 5 partial.
  - Test integrity: confirmed.
- New findings (all bounded, class (b)):
  - **F5-1 (MEDIUM).** `git reset --hard|--keep|--merge -` gives none. The NF-2 mapping makes `-` an operand, which suppresses the `reset --hard` item, and the tree policy drops `-` as a flag. It produced a state item at 2d5a295. Precondition: Git accepts `reset -`, which is not verified.
  - **F5-2 (LOW to MEDIUM, regression).** `guard-writes.sh` `ask_unverified` exits before the later deny checks: look-alike, subagent `.git/hooks|info|config` and learning-agent. Under a failed lookup or a `GIT_*` hook environment, those denies become ask. The log's claim that "a deny is never lowered" is wrong for them.
  - **F5-3 (MEDIUM; HIGH on Git without `GIT_NO_LAZY_FETCH`; not established).** `hook_git_is_tracked` runs plain `ls-files`, which expands a sparse index and so reads trees. In a partial clone with a cone sparse checkout, that can lazy-fetch: the NF-1 mechanism. It is reached only through the shell-edit hint, which never makes a decision.
  - Existing gaps, not regressions:
    - **P-1:** `=`-joined or abbreviated long options (`git reset --har`, `git switch --orph x`).
    - **P-2:** `git stash -- <paths>` gives none.

## Fix round 6 (owner-authorised 2026-10-12; narrowly scoped to F5-1, F5-2, F5-3, P-1, P-2)
- **F5-2:** `guard-writes.sh` records an unverified lookup and asks only in `pass_write`, after every deny check.
  - Coordinator reproduction with a failing-Git shim: at `8a037c5`, learning-agent token path and backend `.git/config` gave **ask**; now they give **deny**.
  - Regression tests: the learning token path, a learning hard link outside `.agents/`, backend `.git/config`, and a look-alike store path under the token arm all deny, under a failing Git and under `GIT_DIR`. Unverified asks are kept for the coordinator and for a learning hard link inside `.agents/`.
- **F5-3:** `hook_git_is_tracked` (`ls-files`) is removed. The hint is now given for any existing regular file, with no Git call. That is harmless context, never a decision.
  - The hook-time Git interface is the four `rev-parse` lookups only. The NF-1 hostile-fixture shim test asserts exactly that, plus no `ls-files`, `cat-file`, `diff-*`, `hash-object`, `for-each-ref`, `show` or `log`.
  - The coordinator's dynamic check (`scratchpad/f53/repro.sh`) **did not reproduce** a lazy fetch from `ls-files`. It used a `tree:0` partial clone with a cone sparse checkout and a sparse index, paths inside and outside the cone, Git 2.46.0, with and without `GIT_NO_LAZY_FETCH`. The finding was mooted by the removal, not confirmed.
- **F5-1:** a hard, keep or merge `reset` asks whatever its target. Local Git 2.46.0 **rejects** `git reset --hard -` ("option '-' must come before non-option arguments"); the guard does not rely on that.
- **P-1:** `git_long_option` matches abbreviated and `=`-joined long options, and is used only to add asks.
  - The coordinator's comparison caught one exemption it had widened: `git restore --sta .` went ask → none. The exemption now needs the exact `--staged`/`-S`.
  - Git 2.46.0 accepts `reset --har`, `switch --orph x`, `switch --orphan=x`, `checkout --orphan=x`, `checkout --for` and `restore --so=x .`; it rejects `reset --hard=x`.
- **P-2:** a stash's action is its first operand before `--`. Only list, show, drop, clear, create and store get no item. Git accepts `git stash -- f` and `git stash push -- f`.
- Verification (coordinator):
  - `tests/run.sh`: 1884 passed, 0 failed.
  - `scripts/check.sh`: `CHECK: PASSED`. Executed: plugin and marketplace validation, script syntax (`bash -n`), hook tests, template names, version consistency, context budget, model routing. **ShellCheck: skipped (not installed).**
  - Marker exploit: 0 failures, no marker.
  - Test integrity: `tests/run.sh` +89/−3; the 3 removed lines are the NF-1 interface assertion, replaced by a stricter one.
- **Prompt burden:** 1205 corpus commands run through `8a037c5` and round 6, as coordinator and backend. 14 coordinator commands go none → ask, and nothing else changes. They are all the newly recognised forms: abbreviated or `=`-joined options, `reset … -`, and `stash -- <paths>`.
- **ShellCheck options (owner approval needed; not done):** `brew install shellcheck` (0.11.0, a Homebrew bottle), or the Docker image `koalaman/shellcheck` against a read-only mount. Docker is present. Until one is approved, ShellCheck has never run on WORK-001.

## ShellCheck (2026-10-12, first run on WORK-001)
- The owner installed ShellCheck with Homebrew: `/opt/homebrew/bin/shellcheck`, version 0.11.0.
- `scripts/check.sh` at `51ed302` now runs ShellCheck, and **it fails: `check.sh` exits 1.**
  - Findings: 14 warnings and 23 notes (`-f gcc`, the files `check.sh` lists).
  - No implementation code was changed, per the owner (the review was running).
- **Pre-existing:** the same ShellCheck run on tag `v0.2.0`'s files also fails, with 2 warnings and 3 notes (`lib.sh` SC2034 ×2; notes in `external-review.sh`, `gate-fast.sh` and `run-gate.sh`). The gate has therefore never been green with ShellCheck present; earlier `CHECK: PASSED` results all had ShellCheck skipped.
- Coordinator triage, by reading the code (not yet fixed):
  - 11× SC1091 (note): ShellCheck cannot follow `source ./lib.sh` and `source guard/hook-git.sh`, because the paths are resolved from the cwd. This causes the cross-file false positives:
    - SC2154: `impact_decision` and `hook_git_output` "not assigned";
    - SC2034: `hook_git_output_file`, `hook_git_output`, `gates_*` and `impact_classes` "unused".

    The likely fix is `--source-path=SCRIPTDIR` or per-file directives in `check.sh` and the scripts.
  - SC2221/SC2222 in `guard-bash.sh:390`: `*cp*` makes the later `*cpio*` redundant in the lookup trigger. Both lead to the same branch, so it is harmless and is a cleanup.
  - SC2053 in `guard-writes.sh:145`: `component_matches` deliberately glob-matches (`[[ $1 == $2 ]]`). Needs a directive.
  - SC2034 in `tests/run.sh:2272` (unused loop variable `attempt`), SC2016 ×4 and SC2012 ×4 (notes): style.
  - Nothing in the triage indicates a security defect. That is an assessment, not a passed check.

## Focused security re-review 6 (Opus, 8a037c5..51ed302)
- Static review: Read, `git diff` and `grep`. No probes were run and none was denied.
- **Resolved:** F5-1, F5-2, F5-3, P-2.
  - The hook-time Git is the four `rev-parse` lookups through `hook_git_run`; none reads the index, trees or objects.
  - No `git_long_option` use grants an exemption, and nothing in the diff lowers an ask or a deny.
  - Test integrity: confirmed.
- **Partial:** P-1, because of N6-1.
- **N6-1 (MEDIUM, bounded; not a general bypass):** abbreviated value-taking options are still matched exactly (`git_pathspec_file`, `consumes_value`/`git_state_value_flags`, `git_tree_ref_restore`'s `-s|--source`).
  - Reported cases for the coordinator: `git restore --pathspec-fr list.txt`, `git checkout HEAD~3 --pathspec-fr list.txt` and `git restore --so=HEAD~3 --pathspec-fr list.txt` get none where the exact spelling asks.
  - `git stash --mess list` is read as the `list` action (none); it already gave none at `8a037c5`.
  - Git's acceptance of `--pathspec-fr` and `--mess` has not been verified.
  - Not fixed: the owner said no further remediation while the review was running.

## Fix round 7 (owner-authorised 2026-10-12; N6-1 and the ShellCheck failures only)
- **Git syntax, established in scratch repositories** (`scratchpad/syntax/n61.sh`, Homebrew Git 2.46.0 and Apple Git 2.39.5, identical results):
  - Accepted, and changing the state file:
    - `restore --pathspec-fr list.txt` and `restore --pathspec-from=list.txt` (restored from the index);
    - `restore --so=HEAD~1 --pathspec-fr list.txt` and `checkout HEAD~1 --pathspec-fr list.txt` (restored from an older commit);
    - `checkout --pathspec-fr=list.txt`.
  - Accepted, and creating a stash: `stash --m list`, `stash --mess list`, `stash --mess show`, `stash --message=list`, `stash [push] --pathspec-fr list.txt`.
  - Accepted, index only: `reset --pathspec-fr list.txt`.
  - Rejected as ambiguous: `restore --s` (`--source` or `--staged`).
- **N6-1 fix (policy.jq and classify.jq):**
  - `git_expand_value_options($names)` spells out an abbreviation that is a unique prefix of the subcommand's long value options. `git_state_items` and `git_tree_ref_restore` judge both the original and the expanded arguments and keep the union, so a wrong expansion can only add an ask.
  - `git_pathspec_file` accepts abbreviated and `=` spellings. `checkout --pathspec-from-file` asks with or without a ref; the exact `checkout --pathspec-from-file=list.txt` with no ref was also none before.
  - Specialist side, found while testing: `git_read_form` and the fallback treated `git stash -m list` (even exact) and `git stash --mess list` as the read form `stash list`, so a specialist got ask, not deny. `list` and `show` are now reads only as the first argument, as Git parses them.
  - Exemptions keep their exact spelling (`--staged`/`-S`).
- Regression table "round 7 N6-1": 31 cases, covering the accepted forms, an ambiguous form, the exact exemptions, specialist denies, and fallback-entry denies with NBSP.
- **ShellCheck** (`/opt/homebrew/bin/shellcheck`, 0.11.0):
  - `check.sh` now runs `shellcheck -x --source-path=SCRIPTDIR <plugin scripts/*.sh, scripts/guard/*.sh, tests/run.sh, scripts/check.sh>`. No rule is disabled globally and the gate still fails on any finding. The "not installed; skipped" branch is unchanged.
  - With sources resolved, 26 diagnostics were left from the 37 artefact-laden ones.
  - Fixed in code:
    - the redundant `*cpio*` pattern in the `guard-bash.sh` root-lookup trigger (SC2221/2222);
    - an unused loop variable (SC2034);
    - four `ls | tr` marker listings, replaced by a glob helper `names_in` with identical output (SC2012);
    - six `source "$scripts/lib.sh"` lines in tests, given `# shellcheck source=` (SC1091, and the dependent SC2154).
  - Narrow per-line directives, each with its reason:
    - SC2329: `cleanup`, invoked by the EXIT trap.
    - SC2053: `component_matches`, a deliberate glob.
    - SC2034: the outputs `gates_source`, `gates_note`, `impact_classes` and `hook_git_output`, read by the scripts that source them.
    - SC2016 ×4: a literal `$` in generated test data and programs.
  - **Result:** `shellcheck` exit 0; `scripts/check.sh` `CHECK: PASSED` with ShellCheck executing. Sections run: plugin and marketplace validation, script syntax (`bash -n` + ShellCheck), hook tests (1914 passed, 0 failed), template names, version consistency, context budget, model routing.
  - **v0.2.0 baseline** with the same options: exit 1, only `lib.sh` SC2034 ×2 (`gates_source`, `gates_note`). Both are now covered by directives; there are no other differences.
- No lowering (coordinator):
  - 1227 corpus commands through `51ed302` and round 7, coordinator and backend. Changes: 14 coordinator none → ask, 5 backend none → deny, 2 backend ask → deny. Nothing was lowered.
  - `tests/run.sh` removed lines: only the `ls` → `names_in` swaps and the loop-variable rename, which are equivalent.
  - Marker exploit: 0 failures.
- **Prompt burden:** the 14 new coordinator asks are all the newly recognised N6-1 forms (abbreviated pathspec-file, source and message options, and `checkout --pathspec-from-file`).
- Evidence gaps (unchanged, open):
  - RR3-12 has not been independently probed.
  - The historical probe corpus is lost and not reconstructed.

## Focused security re-review 7 (Opus, 51ed302..fd52596)
- Static review: `git diff`, `git show`, `grep`, Read. No probes were run and none was denied.
- **N6-1: RESOLVED.**
  - The union only adds asks: the original pass is always included, and expansion can only produce names from the subcommand's value-option list, never `--staged`.
  - Exemptions keep their exact spelling.
  - `git_pathspec_file`, the checkout pathspec-file item and the `--source` abbreviations are covered.
  - The stash read-form narrowing causes no false deny (`stash list --oneline` and `stash show -p stash@{1}` stay reads).
- **ShellCheck changes: acceptable.** The directives are single-line, each has a reason, there is no `.shellcheckrc` and no global disable, and the gate still fails on any finding. The `*cpio*` removal, `names_in` and the loop-variable rename do not change behaviour.
- **Test integrity: confirmed.** Correction to "Fix round 7": the "round 7 N6-1" table has **30** cases, not 31.
- **N7-1 (MEDIUM as reported; bounded).** The `git_state_items_one` stash branch takes the action as the first positional after a leading option, so `git stash -u list <path>` would read as `list` (none). The precondition was inferred from Git's parse-options.
  - **Coordinator check** (`scratchpad/syntax/n71.sh` and a bash re-check, Git 2.46.0 and Apple Git 2.39.5): Git **rejects** these forms: "fatal: subcommand wasn't specified; 'push' can't be assumed due to unexpected token 'list'", exit 128, no stash, state file unchanged.
    - The same happens for `stash -q <path>`, `-k show <path>` and `-u drop`.
    - An implicit push with paths is accepted only after `--` (`git stash -q -- <path>`: stashed and reverted), and P-2 already asks for it.
    - `git stash push -q list <path>` treats `list` as a pathspec and errors when it matches nothing. `push` is not in the no-item list, so it asks either way.
  - So the guard's reading differs from Git only for commands Git refuses, on both supported versions. It is not exploitable on them. It is a robustness gap, not fixed; aligning the stash action with "first argument only" would need owner authorisation.
- Verdict: N6-1 resolved; ShellCheck sound; nothing lowered; no new HIGH.

## Closure pass (owner-authorised 2026-10-12: RR3-12, the lost probe evidence, N7-1)
- **N7-1 fix:** the `git_state_items_one` stash action is now the first argument when that is a stash subcommand, and otherwise a push (as Git parses it, and as `git_read_form` does since round 7).
  - Git behaviour (scratch, 2.46.0 and Apple 2.39.5): `stash <option> list|show|drop <path>` is rejected; `stash -q -- <path>` is the accepted implicit push.
  - Regression table "closure N7-1": 13 cases. The read forms `list`, `list --oneline`, `show -p stash@{1}`, `drop` and `clear` stay none, and the specialist reads too.
  - Coordinator comparison against `fd52596` (1241 commands, coordinator and backend): 5 coordinator none → ask, all N7-1 forms; nothing else changed.
- **Replacement probe set (`tests/guard-probes.txt`; not the lost corpus).**
  - 45 risk-focused probes, run by `tests/run.sh`, one line per boundary:
    - 15 for the v0.2 floor;
    - compound deny;
    - 6 Landra false-positive categories;
    - 6 evasion, including NBSP fallback and a newline context prefix;
    - 6 specialist Git;
    - 3 authority store;
    - 7 protected trees and state-changing Git.
  - The test asserts the set has at least 45 probes.
  - **One-off comparison with the v0.2.0 install** (cache identical to the tag), in a feature-branch scratch repository. After a coordinator harness error was corrected, it gave:
    - ask → ask: 17;
    - ask → deny: 2 (the compound denies);
    - none → ask or deny: 15 (new coverage: vercel/neon, evasion, specialist Git, the store, protected trees, Option B);
    - ask → none: 4 (the Landra false-positive categories, by design: AC1);
    - none → none: 7.
    - The harness error: one comparison line kept a literal `$'\n'`. Rerun with a real newline: v0.2 ask, now ask.
  - **Not available:** comparability with the historical 674 + 36 probes and their earlier `compare.sh` results. The lost corpus is not recovered or reproduced; this set replaces it as forward regression evidence only.
- **RR3-12: independent verification, step 1 (design; security-reviewer, static).**
  - The reviewer confirmed from code that the hook never executes the submitted command text. Evidence:
    - jq parsing only: `main.jq:26,32`, `fallback.jq:7`;
    - hashing and `grep` only: `guard-bash.sh:82,84,212`;
    - the only filesystem touch derived from the command: `[ -f ]` at `guard-bash.sh:347`;
    - no `eval`, `bash -c` or `sh -c` in the hook scripts.
  - It designed 20 probes: 12 for case variants and overwrites, 4 specialist, 4 harmless. It predicts 4 gaps (probes 9-12: `dd of=`, `sort -o`, `1<>`, a first-write `>>`, each letting a staged patch reach `git apply` with no decision).
  - Step 2 (execution) pending: inert fixtures are in `scratchpad/rr312/probes.jsonl`, written by the coordinator verbatim from the design, with the fixed runner `scratchpad/rr312/run.sh`.
- Verification:
  - `tests/run.sh`: 1973 passed, 0 failed.
  - `scripts/check.sh` with ShellCheck 0.11.0 executing: `CHECK: PASSED`.
- **RR3-12: independent verification, step 2 (executed at `cc63324`).**
  - The security-reviewer confirmed that the fixtures match its design and that the runner cannot execute probe text. It ran the fixed runner once; it was not denied.
  - **Tested results** (20 probes):
    - 15 as expected.
    - Probe 1 gave deny, stricter than ask. The coordinator confirmed the reason from the fixture: `sh deploy.sh [unclassified-deploy]` was bundled with other commands. That is the deploy-path rule, a probe-design artefact.
    - **4 gaps confirmed, 9-12: none where ask was expected.**
  - What RR3-12 itself covers, now tested independently: case-insensitive matching, untrusted non-exact spellings, appends that accumulate, and overwrites by `cp`/`tee`. Harmless controls stay none and specialist script writes deny.
  - **New bounded gaps G12-1 to G12-4 (MEDIUM, class (b): an incomplete list of overwrite forms, not a general parsing or trust bypass).** A patch file written in the submission and then replaced without the guard seeing its content reaches `git apply` with no decision:
    - **G12-1:** `dd of=<file>`: `overwrite_targets` keys the whole word `of=…`.
    - **G12-2:** `sort -o <file>`: `sort` is not in `file_writer_programs`. `uniq`, `yq`, `xxd`, `base64` and `iconv` are probably similar (not run).
    - **G12-3:** `1<>` (and probably `>&<file>`, not run): not a write op in `collect_context`.
    - **G12-4:** a first write with `>>` is treated as the whole file.
  - Precondition: content staged outside the guard's view (for example with the Write tool). Effect: the protected-tree ask, and the authority-store deny for a patch that targets a state file, are skipped.
  - Code-reading note (low): the SQL `-f` and shell `<` paths ignore the known flag; the keyword floor masks it today.
  - **Not fixed:** outside this pass's authority. The owner must decide to fix or to accept explicitly.
- Static review of `fd52596..cc63324` (same reviewer):
  - N7-1 is sound: nothing lowered, and no read form misread.
  - The probe set and its loader are sound and add-only. A future comment containing `|` would be read as a probe, and most likely fail loudly.

## RR3-12 closure fix (owner-authorised 2026-10-12, option 1: G12-1 to G12-4)
- **Security-design assessment (before implementing).**
  - Observable: only the text of each Bash submission (PreToolUse), and Write/Edit/NotebookEdit target paths.
  - Not observable:
    - file contents on disk;
    - writes made by earlier calls, the Write tool, editors or processes running alongside;
    - filesystem aliasing set up outside the submission (a symlink or hard link `g` → `f.patch` made in an earlier call).
  - Known content is per submission: a patch or script is known only if the submission wrote it with exact-content writers (echo, printf, heredoc, here-string) and nothing else in the submission can be seen to change it.
  - The decision classes are separate:
    - unknown patch content asks (N6(b));
    - a protected path reached by a recognised operation asks (protected-tree policy);
    - a positively identified store or Git-file write denies, and deny precedes ask in `decide`.
  - G12-1 to G12-4 were false "known" claims after a change inside the submission that the guard failed to recognise. They are within the model, so the architecture is adequate for the spec's guardrail property.
  - **Structural limit (not fixable within the hook boundary):** aliasing created outside the submission, and concurrent external writers, can change a "known" patch or script unseen. This falls under the documented residual ("not a defence against a deliberately adversarial process with shell access"). The fix does not claim to cover it.
  - The stricter alternative, for an owner decision, not implemented: never trust patch content, so every coordinator `git apply`/`patch`/`am` asks. That changes the N6(b) ruling for known safe patches.
- **Fix** (classify.jq `overwrite_targets` and `collect_context`; policy.jq `patch_findings`):
  - Overwrite detection fails closed instead of extending the list of writers:
    - an unlisted program that names a written file counts as a writer;
    - known readers and metadata do not (readonly_programs, context commands, chmod/chown/chgrp/touch);
    - readers with an output option (`output_option_flags`: sort, base64, less, iconv) do;
    - word values count (`of=F`, `--output=F`, `-oF`).
  - `<>` and `>&<file>` are writes with unknown content (`>&<fd>` stays a duplicate).
  - A first write that appends (`>>`, `&>>`, `tee -a`) is unknown content.
- **Deny precedence (found during the fix):**
  - The first version turned these from **deny** (at `cc63324`, which trusted the written text) into **ask**: a store-targeting patch written in the submission and then overwritten (`dd`, `sort -o`, `1<>`, `>&`, an unknown program) or first-written by append.
  - `patch_findings` now checks the hunks the submission wrote for store and Git-file paths whether or not the content stays known. Unknown content additionally asks, and deny wins. All these cases deny again (fixtures `scratchpad/rr312-fix/probes.jsonl`, d1-d8: 0 mismatches).
- Evidence:
  - The independent RR3-12 probes (`scratchpad/rr312/run.sh`), rerun on the fix: probes 2-20 as designed, including 9-12, which now ask. Probe 1 still denies (deploy-path artefact).
  - Regression table "RR3-12 closure", 28 cases:
    - probes 9-12 and variants (`dd of=` with either case, `sort -o`/`--output=`/`-oF`, `base64 -o`, `uniq`, an unknown program, `1<>`, `>&<file>`, first-write `>>`/`&>>`/`tee -a`);
    - 5 store or specialist denies;
    - 8 harmless controls (`wc`, `chmod`, `grep`, an exact-then-append patch, an unrelated unknown-program output, `2>&1`, `sort -o` of an unrelated file).
  - `tests/run.sh`: 2000 passed, 0 failed. No existing expectation changed; the only `tests/run.sh` change is additions.
  - `scripts/check.sh` with ShellCheck 0.11.0 executing: `CHECK: PASSED`.
  - Comparison with `cc63324` (1266 commands, coordinator and backend): 12 coordinator none → ask, all of them gap forms. Nothing was lowered.
- **Prompt burden:** asks are added only where a patch the submission wrote is then changed by an unrecognised or non-exact write before `git apply`. Harmless reads and metadata between write and apply add none (tested).
- **Dogfood (2026-10-12):** an inline `bash -c` comparison script was blocked by a Claude Code built-in safety check ("passes a shell -c script that runs rm"). The script contained no removal; the trigger was not verified. It was not re-issued through another shell; the cases ran through the inert fixture runner instead.
- Evidence gaps: RR3-12's "probably similar" writers that were not run individually (`yq`, `xxd`, `iconv`, `less -o`) fall under the fail-closed rule, or are listed writers. The historical probe corpus is still not reproduced.

## Independent review of the RR3-12 closure fix (security-reviewer, 63e8c7d..38465e0)
- Static verdict:
  - G12-1..G12-4 are fixed. Nothing is lowered: the changes only set k=false or add deny.
  - NR-3c (the parse of a run script) is unaffected.
  - Test integrity: confirmed, add-only.
- **Tested by the coordinator** with the inert runner (`scratchpad/rr312-r2/probes.jsonl`, the reviewer's 12 probes verbatim, at `38465e0`):
  - **r1-r3 and r5 give none (expected ask)** for a patch the submission wrote and then replaced:
    - r1: `cp other/f.patch .` (the destination is a directory);
    - r2: `curl -fsSLO https://…/f.patch` (the name comes from the URL; the content arrives from the network inside the submission, nothing staged);
    - r3: `ln -s f.patch g.patch` before the write, then `> g.patch` (aliasing inside the submission);
    - r5: `env -C src cp ../other.patch ../f.patch` (the wrapper chdir is not followed).
  - **r6:** `cat f.patch | git apply` of a store-hunk patch the submission wrote gives ask, not deny (the pipeline producer's text is unknown).
  - r4, r7-r12 as expected. That includes the subshell `cd`, the case variant, the echo-built store patch denying, `--include='*'` with no false deny, and no raise for `shellcheck r.sh`.
  - All five mismatches give the same result at `cc63324`. At v0.2.0, r1-r3 and r5 also give none, and r6 none (v0.2 had no patch rules). **Not regressions.**
- Reviewer, on the trust boundary: concurrent external writers are genuinely unobservable. An already existing symlink could be detected at hook time (a `realpath` stat), so not doing so is a trade-off, not a hard limit. Aliasing set up inside the submission and network or archive content are within the model and not handled.
- **Coordinator assessment: the "known patch ⇒ no decision" model is incomplete by enumeration.**
  - Two independent rounds have each found new in-submission ways to replace a written patch: G12-1..4, then r1-r3 and r5.
  - The space of writers (directory destinations, URL- or archive-derived names, aliasing, wrapper chdirs, …) is open-ended.
  - Per the owner's stop condition, no further remediation was started; an architectural decision is requested.
- Prompt cost of removing that trust:
  - 14 coordinator commands in the test corpus apply a patch with no decision today.
  - 7 are file patches the submission wrote.
  - 5 pipe a heredoc straight into `git apply` or `patch`, with no file and so no window to replace it.
  - 2 are `--check`/`--dry-run`.

## Owner decision (2026-10-12): option 1, stop trusting file-backed patches
- An explicit architectural decision. It **replaces the N6(b) exception** that let a proven-safe file-backed patch through without approval, and removes the open-ended patch-file provenance problem instead of adding writer detection.
- **Implementation** (classify.jq patch content; policy.jq `patch_dry_run`):
  - Patch content read from a file (an operand, `-i`, or `<` redirection) is never known, whoever wrote the file. A mutating `git apply`/`git am`/`patch` of a file therefore asks for the coordinator.
  - Content given directly on standard input (a heredoc or here-string, or echo/printf/bare-`cat` of one, through a pipeline) is still judged by content. It is inline in the command and cannot be replaced through a file.
  - The decision does not depend on writer tracking, provenance, links, downloads, concurrency or earlier commands. No parser, tracker or Git inspection was added.
  - Deny precedence: the hunks this submission wrote into a file it applies, directly or through `cat FILE |`, are still checked. A store hunk, or a Git-file hunk for specialists, denies.
- **Probe r6 (`cat f.patch | git apply`):** the guard cannot establish the applied content from trustworthy data, because it comes from a file.
  - It can establish that the submission itself wrote store hunks into that file and pipes the file into `git apply`. That is a positively identified attempt to apply store hunks, so it **denies** (ask → deny).
  - A file this submission did not write cannot be read, so its target is unknown and it asks. **Documented limitation:** a store-targeting patch staged outside the submission is an ask (coordinator approval), not a deny.
- **Dry runs (verified, scratch repositories, Git 2.46.0 and Apple 2.39.5; Apple patch 2.0):**
  - `git apply --check` writes nothing; `git apply --check --ap` **applies the patch** (abbreviated `--apply`); `--stat --apply` applies; `--build-fake-ancestor` errors in these runs.
  - `patch --dry-run`/`-C`/`--dry`, even with `-o`, wrote nothing.
  - **Fix:** `patch_dry_run` for `git apply` now excludes any `git_long_option(["--apply", "--build-fake-ancestor"])`. Before, `--check --ap` gave none.
- Tests:
  - 9 expectations changed none → ask: file-backed applies of patches this submission wrote, each commented with this decision.
  - New table "closure option 1", 25 cases:
    - r1, r2, r3 and r5 ask; r6 denies;
    - store hunks in an applied file deny (`git apply`, `patch <`);
    - the file-backed forms ask (`git apply`, `--index`, `git am`, `patch <`/`-i`, `cat | git apply`);
    - fake dry runs ask; real dry runs stay none;
    - direct-heredoc controls stay none, and store heredocs deny;
    - specialists deny.
  - The independent fixture sets: rr312-fix d1-d8 all deny; rr312-r2 r1-r11 as expected, r12 now ask (file-backed, as decided); rr312 probe 19 now ask (file-backed); probe 1 is the deploy-path artefact.
- Verification:
  - `tests/run.sh`: 2025 passed, 0 failed.
  - `scripts/check.sh` with ShellCheck 0.11.0 executing: `CHECK: PASSED`.
- **Comparison with `38465e0`** (1284 corpus commands, coordinator and backend):
  - 13 coordinator none → ask: 11 file-backed applies and 2 fake dry runs.
  - 1 coordinator ask → deny (r6).
  - Nothing lowered, and nothing else changed.
- **Prompt measure (corpus only, no real-world extrapolation):** 13 of 1284 corpus commands newly ask for the coordinator. The 5 direct-heredoc patch applies in the corpus stay no decision.

## Independent re-review of option 1 (security-reviewer, d49598e..891e82b)
- Static verdict:
  - Option 1 is implemented correctly for the documented forms.
  - Rules 2, 6 and 7 hold; rule 3 holds except through G2.
  - r6's ask → deny is justified; the limitation is accurate but narrower than it reads: other producers (`head f |`, `< <(cat f)`, xargs) ask, not deny.
  - Test integrity confirmed: exactly the 9 authorised none → ask expectation changes and 25 additions.
- **Tested by the coordinator** (inert runner, `scratchpad/opt1-r/probes.jsonl`, the reviewer's 14 probes verbatim, at `891e82b`): **p1-p9 give none.** p10-p14 as expected (`git apply - < f`, `<(cat f)`, `echo "$(cat f)" |` and `env git apply < f` ask; the real dry run `--check --exclude=x` stays none).
- Gaps confirmed, all in option parsing for the patch tools:
  - **G1 (HIGH as reported):** `xargs git apply <<'EOF'\nfix.patch\nEOF` and `<<< fix.patch`. The xargs heredoc is taken as patch content, though it supplies the file name.
  - **G2 (HIGH as reported):** `git apply --exclude --check fix.patch` is treated as a dry run because `--check` is taken as a flag. Git takes it as the value of `--exclude` and applies. With a store patch the submission wrote (p4), the result is none instead of deny. `patch -p1 -i --dry-run` is the same shape.
  - **G3 (MEDIUM):** `cat -- -fix.patch <<'EOF' | git apply`. A file after `--` is read as an option.
  - **G4 (MEDIUM):** `patch -p1 -fi F`, `--inp=F` and `--inp F`. Bundled or abbreviated input options are missed, so a decoy heredoc decides.
- **Real behaviour (scratch; Git 2.46.0 and Apple 2.39.5, Apple patch 2.0):**
  - `git apply --exclude --check fix.patch` applies (both Gits); `--check --exclude=x` does not.
  - `xargs git apply <<< fix.patch` applies.
  - `patch -fi fix.patch`, `--inp=fix.patch` and `--inp fix.patch`, with a decoy on stdin, apply `fix.patch`.
  - `patch -p1 -i --dry-run` errors (exit 2) and writes nothing.
- **Not regressions:** p1-p9 also give none at `38465e0`, at `cc63324` and at v0.2.0.
- Not fixed: outside the option-1 authorisation, so an owner decision is requested. Coordinator assessment: like N6-1 and P-1, these come from emulating each tool's option grammar (values, bundles, abbreviations, `--`, xargs argument injection), which is open-ended.

## Owner decision (2026-10-12): fail closed for patch tools
- An explicit architectural decision: no further enumeration of patch-command bypasses.
- **Allowed exemption shapes (the whole list).**
  - Each shape requires an unwrapped command: the first word is `git`/`patch`, with no xargs/env/sudo/time or other wrapper.
  - It also requires no dynamic word, no Git global option, no pipeline producer, and exactly the stated redirections.
  - Flags are matched as whole words only: abbreviations, combined flags, `=` values and value-taking options never qualify.
  - **D1** (no decision): `git apply --check|--stat|--numstat|--summary [-pN] FILE…`. Exactly one of the four flags, no redirection, at least one file. Safe because no value-taking option can swallow the dry-run flag (G2), and the flags only read.
  - **D2** (no decision): `patch --dry-run [-pN]`, with stdin either one `<` or its own heredoc, and no operand or `-i`. Safe because the input is stdin only and the dry run writes nothing.
  - **H1 / H2** (judged by content): `git apply [-pN]` / `patch [-pN]`, whose own stdin is a heredoc or here-string and nothing else. Safe because the content is literally in the command text and nothing can replace it; its paths are checked, so store hunks deny.
  - Everything else is a mutating apply of unknown content and asks: `cat <<EOF | git apply`, `git am`, `-R`, `--index`, wrapped forms, value options, extra redirections, file operands.
- **Deny precedence:** the store and Git-file hunks the submission wrote, or its own stdin text (not a wrapper's), are checked in every shape. Specialists' Git writes stay denied.
- **G1:** a wrapper's standard input is never patch content.
- Implementation:
  - classify.jq builds the patch object with `dry` and `known` from the exact shapes, reusing the command's existing facts (`unwrapped.names`, `raw_head`, `git_parts.globals`, redirections, pipeline producers).
  - policy.jq `patch_dry_run` is now `.patch.dry == true`. The earlier `git_long_option` dry-run exclusion is replaced, not stacked.
  - No new parser, tracker or Git inspection.
- **Real behaviour (scratch, Git 2.46.0 and Apple 2.39.5, Apple patch 2.0):** every D1 and D2 shape (`--check` with two files, `--stat -p1`, `--numstat`, `--summary`, `patch --dry-run -p1 <` and its heredoc form) left the files, the index and the directory unchanged.
- **Tests:**
  - 1 expectation changed none → ask (`cat <<'EOF' | git apply`, commented).
  - New table "fail-closed patch tools", 38 cases:
    - the 9 confirmed gaps p1-p9, all ask or deny;
    - 17 unknown-shape cases that fail closed, e.g. `--chec`, `--ap`, `-v`, a missing file, extra `<`, `git -C`, `env`, `time`, `patch FILE`, `--dry`, `-o`, `-R`, `--index`, `git am`, a dynamic name, `> out.txt`;
    - 2 deny-precedence cases;
    - 10 allowed shapes staying none;
    - 2 specialist denies.
  - All four independent fixture sets rerun:
    - opt1-r: p1-p13 as expected; p14 (`--check --exclude=x`) now asks by design.
    - rr312-r2 and rr312: only the file-backed r12 and probe 19 (asking per option 1), and the probe-1 artefact.
    - rr312-fix: all 8 deny.
- Verification:
  - `tests/run.sh`: 2065 passed, 0 failed.
  - `scripts/check.sh` with ShellCheck 0.11.0 executing: `CHECK: PASSED`.
- **Comparison with `891e82b`** (1319 corpus commands, coordinator and backend):
  - 22 coordinator none → ask and 1 none → deny (p4).
  - 6 backend none → ask: plain `patch` forms. `patch` is not a Git write, so specialists get the same fail-closed ask.
  - Nothing was lowered.
- **Prompt measure (corpus only):** 29 additional asks out of 2638 decisions (1319 × 2 callers), all in patch-tool commands outside the four shapes.

## Independent review of the fail-closed patch policy (security-reviewer, 301a4c2..ab7fd33), and corrections
- Static verdict:
  - The design is right; question 4 (tests and denials not weakened) holds.
  - Wrappers, a heredoc plus `<`, global options, aliases, `-p1` values, an operand named `--check`, and `bash -c`/eval all fail closed.
  - Low, unverified: `$plain` ignores prefix assignments and exported Git variables (`GIT_WORK_TREE`, `GIT_DIR`, `PATCH_GET`); no concrete exploit was found.
- **Tested by the coordinator** (inert runner, `scratchpad/fc-r/probes.jsonl`, the reviewer's 10 probes verbatim, at `ab7fd33`):
  - **F1 (HIGH as reported, bounded):** f1, f2, f4 and f5 gave none. The lexer drops the fd number of a redirection, so `git apply 3<<'EOF'` or `4<<< x` (and `patch --dry-run 3< f`) counted as the tool's own stdin. With `{ …; } < fix.patch` or `exec < fix.patch`, the tool actually applies a file.
  - **F2 (MEDIUM, a deny lowered by `ab7fd33`):** f7-f9 (`time git apply`, `cat <<EOF | git apply` and `git -C . apply`, each with an octal-escaped store name) denied at `301a4c2` and asked at `ab7fd33`. The non-plain shapes had stopped passing their stdin text to the deny check.
  - f3, f6 and f10 as expected.
- **Corrections** (defects in the implementation of the authorised decision; no new architecture):
  - F1: lexer.jq keeps the fd number as `fd` on each redirection (the operator is unchanged). The shape check counts only stdin redirections (no fd, or fd 0) as the tool's own input; any other descriptor makes the shape non-exact.
  - F2: the command's own and producer stdin text always goes into `texts` for the store and Git-file deny. `known` still needs the direct shape, so G1 holds.
- Tests: table "fail-closed patch tools F1 F2", 9 cases (4 ask, 2 fd-0 controls none, 3 deny). All five fixture sets rerun: fc-r 0 mismatches; the others unchanged apart from the documented by-design differences.
- Verification:
  - `tests/run.sh`: 2074 passed, 0 failed.
  - `scripts/check.sh` with ShellCheck 0.11.0: `CHECK: PASSED`.
  - Comparison with `ab7fd33` (1328 commands, coordinator and backend): 4 coordinator and 2 backend none → ask (F1 forms), and 3 coordinator ask → deny (F2 restored). Nothing lowered.

## Confirmation review of the F1/F2 corrections (security-reviewer, ab7fd33..9bb143a)
- **Approved for F1 and F2.**
  - F1 is closed: any non-stdin descriptor, `<&`, `<>`, `<&-`, an extra redirection, two heredocs or `00<<` makes the shape non-exact. An earlier `exec 0<f` cannot matter, because the command's own fd-0 heredoc takes precedence.
  - The lexer change has no side effects: no whole-object comparison, `pending_fd` is never stale, and heredoc indexing and `.bad` are unchanged.
  - F2 is closed with G1 kept. Test integrity is sound.
  - Low: only the patch shape uses `fd`; `own_stdin` elsewhere (SQL clients) still treats `3<<` as stdin. No decision change was found.
- **New finding N1 (HIGH as reported, bounded; not introduced by this work).** The lexer recognises `<<-` but does not strip the leading tabs from the body, so `patch_paths` (anchored `^---`, `^+++`, `^diff --git`) finds no headers. Bash strips the tabs, so the tool applies the real hunks.
  - **Tested by the coordinator** (`scratchpad/n1/probes.jsonl`, tab-indented bodies as JSON `\t`, at `9bb143a`):
    - n1 (`git apply <<-` with a C-quoted, octal-escaped store name) gives **none**, expected deny.
    - n1d (the same with `patch -p1 <<-`) gives **none**, expected deny.
    - n1c (`git apply <<-` with a harmless `src/x` patch) gives none. It qualifies as H1 although its content is misread; under fail-closed it should ask.
    - n1b (a plain store name in `<<-`) gives deny: the `.state.json` text match still catches it.
  - Same results at `ab7fd33`, `891e82b` and `38465e0`. At v0.2.0 all four give none. **Not a regression.**
  - **Not fixed:** outside the authorised scope; owner decision requested. Candidate fixes:
    - (a) strip leading tabs from `<<-` bodies in the lexer, as Bash does. This affects every heredoc consumer (SQL scans, scripts, patches) and makes them more correct.
    - (b) exclude `<<-` from the H1/H2 shapes, so it asks. Without (a), the deny for octal-escaped store names inside `<<-` stays an ask.

## Finding status (verified facts only)
| Finding | Status |
| :- | :- |
| F-T1-1 | Resolved: closed by T3, test proves no execution, confirmed by the security review |
| F-T3-1 | Resolved: env switch removed, regression tests, confirmed by the security review |
| F-SEC-0, F-SEC-0b, H1–H6, M1–M4, L1–L3 | Open: fix round 1 implemented. Verified by the coordinator:<br>- fast gate `GATE fast: PASSED (exit 0) command: tests/run.sh` (912 passed);<br>- `compare.sh` with 0 mismatches and 0 v0.2-ask→none regressions on all three probe sets (101 Git, 221 HTTP/SQL/platform, 184 fix probes);<br>- `tests/run.sh` against `main` has 0 removed lines; one T2 expectation was made stricter (specialist bare `git checkout`: none→deny).<br>Focused re-review done: H2, H3, H4, M2, M4, L1, L2, L3 are **resolved**, and H6 is resolved for ASCII (Unicode folding continues under N6). H1, H5, M1, M3, F-SEC-0 and F-SEC-0b are **open** (partially resolved; fix round 2). |
| N1–N6 (including the owner's N6 ruling), H1/H5/M1/M3 remainders | Open: fix round 2 implemented. Coordinator verification (independent of the agent's report; it was produced while the auto-mode safety classifier was unavailable):<br>- diff limited to the guard scripts, `tests/run.sh`, docs, changelog and log; no protected or system file changed;<br>- the only removed test lines are the 8 KB fixture generator and info line, replaced by a genuine 8159-byte fixture with a size assertion;<br>- the installed v0.2 cache is identical to tag `v0.2.0`, the install record is `b875f32`, and there is no `--plugin-dir`;<br>- `GATE fast: PASSED (exit 0) command: tests/run.sh` (1240 passed);<br>- `compare.sh` gives 0 mismatches and 0 v0.2-ask→none regressions on all four probe sets (552 probes); the probe-file edit changed only the two N6 lines (`any`→`ask`).<br>Focused re-review pending; not resolved until it confirms. |
| Re-review 2 verdicts at 38bfb88 | **Resolved:** N1 (listed shapes), N4, M1, N6 log rotation. **Open:** N2 (restricted-agent Git environment), N3, N5, N6 Unicode, N6 owner ruling (partial), H1, H5, M3 remainders. |
| NR-1 to NR-5, H5 environment, N6(a)(b)(c) rulings | Open: fix round 3 implemented. Coordinator verification:<br>- diff limited to the guard scripts and `tests/run.sh` (plus coordinator docs, spec and log); no protected or system file changed, and `guard-writes.sh` is unchanged;<br>- the only removed test lines are an outdated comment about the old 8 KB target;<br>- the v0.2 cache is identical to `v0.2.0`, the install record is `b875f32`, and there is no `--plugin-dir`;<br>- `GATE fast: PASSED (exit 0) command: tests/run.sh` (1409 passed);<br>- `compare.sh` gives 0 mismatches and 0 v0.2-ask→none regressions on all five probe sets (674 probes);<br>- my 27 original re-review-2 expectations are kept or strengthened (three NR-3c write-then-run cases ask→deny; boundary lines set to the owner's rulings).<br>Focused re-review pending. |
| N6 boundary (a), (b), (c) | Owner ruled 2026-10-07; implemented in fix round 3. Re-review 3: (a) **not resolved** (RR3-1, RR3-4 to RR3-7); (b), (c) partially resolved (RR3-8, RR3-9) |
| Re-review 3 verdicts at f1fb238 | **Resolved:** NR-1, NR-2, NR-3a/b, NR-5, N6 Unicode, H1 remainder. **Open:** NR-3c, NR-4, H5, N2, N5, M3, N6(a)/(b)/(c), RR3-1 to RR3-13 |
| RR3-1 to RR3-13 and the re-review-3 remainders | **Open: implemented, not closed.** Fix round 4 is committed as `2d5a295` and coordinator-verified (see "Fix round 4 coordinator verification"); the RR3-1 independent marker exploit ran no repository program. The commit subject says "close RR3-1..RR3-13": read that as "address", because none counts as closed until the focused re-review of `2d5a295` confirms it. The commit was deliberately not amended (owner, 2026-10-12). It is local only, not pushed. |
| Performance, corrected spec (owner-approved 2026-10-07: three properties) | Measured at `2d5a295`, not yet re-reviewed:<br>- (1) typical p95 99 ms over 20 runs, budget 150 ms (coordinator, direct timing; the test asserts the 500 ms CI tolerance);<br>- (2) 471 µs per command, bound 1500 µs, linearity asserted;<br>- (3) 250 KB heredoc 150 ms, budget 1 s.<br>Fixture preconditions are asserted in each test. This supersedes the row below. |
| Performance (spec: p95 < 150 ms up to 8 KB), **superseded by the 2026-10-07 specification correction; kept as the historical record** | **Not met**; see "Performance analysis". Not accepted; an owner recommendation is pending. |

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

