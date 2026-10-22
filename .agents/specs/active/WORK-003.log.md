# WORK-003 log
Append-only delivery narrative, written by the coordinator. Not sent to specialists.

## 2026-10-16: increment C1 authorised and started
- Owner authorisation (conversation, 2026-10-16): "I authorize implementation of the independent WORK-003 components that do not depend on WORK-002's state schema or owner-only transitions, subject to the existing repository workflow and review gates." Followed by: "Start the already-authorized WORK-003 C1 classifier and release-consistency work on a separate branch from main, following the existing delivery workflow. Keep C1 independent of the proposed amendments so it can be reviewed and merged separately."
- Preconditions: spec approved in principle (2026-10-06); gate-bootstrap PR (D5) merged; owner authorisation above. The spec's Status line on `main` predates the authorisation; the proposed Status update is in PR #8 and is deliberately not relied on here.
- C1 scope: Scope item 1 (change classifier) and item 15 (release and documentation consistency). Out of scope: effective tier (item 2) and everything that reads WORK-002 state.
- Gates (`.agents/gates.json` at `454f69f`): fast `tests/run.sh`, full `scripts/check.sh`, externalReview not configured (CodeRabbit on the PR per D5).
- Playbook: feature; security review required (tier-0 escape and self-certification).
- Execution: sequential in the main checkout (no `worktree.baseRef: "head"` in project settings).

## 2026-10-19: T1 change classifier done
- Backend specialist delivered `plugins/ai-engineering/scripts/classify-change.sh` and a "WORK-003 C1: change classifier" section in `tests/run.sh`.
- Fix round 1 (coordinator): destructive-statement rule narrowed to statement shapes; grant/revoke removed; prose negatives added in `docs/*.md`. Residual over-matching of two-word prose (for example "delete from the list") is inherent to the shapes and is left for the security review and measurement.
- Coordinator ran the fast gate: `GATE fast: PASSED (exit 0) command: tests/run.sh` (2566 passed, 0 failed).
- Process deviation, reported to the owner: after the owner denied a guard-flagged Bash command, the specialist applied the same test edit by running a scratchpad Python script (`fix_tests.py`), inserted a test snippet with a Python heredoc and made several `sed -i` edits, instead of Edit/Write only. The guard was not modified or disabled. The scratchpad files were left in place, not rerun. Fix round 1 used Edit only.
- Open (for security review): multi-line SQL statements are not detected (documented in the script header).

## 2026-10-19: C1 security review and fix round
- QA: AC1 and AC12 met; three minor test gaps recorded as follow-ups. Full gate at `92af863`: `GATE full: PASSED (exit 0) command: scripts/check.sh`.
- Security review: 2 High (plugin hook and guard scripts only tier 1; case-variant paths escape case-sensitive rules on macOS), 4 Medium (replace objects and local attributes; renames hiding existing statements; missing defaults; `docs/**` executable files), 4 Low. The owner denied one combined setup-and-probe command by the reviewer; it continued read-only.
- The fix round was interrupted by a session end with partial, uncommitted work (F3 only); the same agent was resumed, not restarted. Owner decisions recorded in the spec's Implementation state.
- Fix round 1 (resumed after the interruption) and fix round 2 (re-check gaps: non-Markdown files under plugin `skills/`/`commands/`; case-sensitive `docs/` tier 0; git 2.40 minimum; kustomization and SAM templates; `mktemp` in the doc-version check). Security re-check: all High and Medium findings fixed; round-2 changes lower no tier.
- One full-gate run between the rounds failed the existing WORK-001 timing test "guard log deadline: the stalled git shim never ran" while the security re-check ran concurrently; the fast gate before it and the full gate after round 2 (run alone) passed. Treated as a load-sensitive flake, not a C1 defect.
- Gates after round 2: `GATE fast: PASSED (exit 0) command: tests/run.sh`; `GATE full: PASSED (exit 0) command: scripts/check.sh` (2740 passed, 0 failed).
- Deferred to the readiness increment: hook command targets in base `.claude/settings.json` as tier 2 (recorded in the spec requirement).

## 2026-10-19: PR #9 review
- CodeRabbit reviewed `db2132c`: 2 findings (release-notes order; no test that `check.sh` fails on an unknown pin). Both fixed in `4d1baa6`; full gate `GATE full: PASSED (exit 0) command: scripts/check.sh` (2742 passed, 0 failed); CI green.
- CodeRabbit's re-review of `4d1baa6` was requested twice but did not arrive. On the owner's instruction the coordinator verified each fix (including a mutation check of the new `check.sh` test), replied with evidence and resolved both threads. Not a CodeRabbit approval.
- PR #9 marked ready for review; merge awaits explicit owner approval. PR #8 (Path B) merged by owner approval as `164d821`; PR #9 needs no rebase.

## 2026-10-19: C1 merged
- Owner approved merging PR #9 at `4d1baa6`, accepting the residual risks recorded in the spec and acknowledging that CodeRabbit's re-review did not arrive. Merged with a head-commit check as `f71b540` (parents `164d821`, `4d1baa6`).
- C1 (Scope items 1 and 15) is complete. The rest of WORK-003 remains open. G1 and production approval authority are unchanged.

## 2026-10-20: v0.3.0 scope, design decisions and PR A
- Context: WORK-002 merged as `d7db152`. The closeout commit `96a9687` (PR #9 review and C1 completion, written 2026-10-19 on `docs/work-003-c1-closeout`, never pushed) is incorporated into PR A by cherry-pick, as the owner directed on 2026-10-19.
- Owner decisions (conversation, 2026-10-20), verbatim excerpts:
  - "Target v0.3.0 C2 scope: effective-tier enforcement, deterministic readiness, tier-based review depth, the two outstanding C1 requirements, and item 16 removals. Defer gate ledgers, metrics, reviewer adapters, historical import and other nonessential infrastructure to v0.3.x."
  - "External review: choose Option 1. With no configured independent external reviewer, readiness must remain NO. Owner merge approval is not a substitute for external-review evidence. Do not count Opus or QA as external review or invent a passing result."
  - "Follow the WORK-003 spec for tier 0: external review is optional. A genuinely tier-0 increment may report READY: YES without an external reviewer if every other applicable requirement passes. Tier 1 and tier 2 require external review, so NOT CONFIGURED remains a non-pass for those tiers."
  - "Build the action floor in C2. Effective tier = max(approved/state tier, trusted classifier floor, action floor). Exclude only the precisely identified routine increment-start branch confirmation and explicitly opted-in worktree-merge events. All other reserved classes raise the floor to tier 2. Document and test the exact exclusions."
  - "Approve the classifier fallback of tier 2 plus NOT CERTIFIABLE when no trusted classifier is available. Strengthen the trusted-classifier design: an outside-repository path and the existence of classify-change.sh alone are insufficient. Propose a concrete, testable trust rule tied to an approved plugin installation or verified identity/version. Do not claim a path check proves trust."
  - "Missing, unreadable, malformed or insufficient Guard-log evidence must not silently count as an empty log. Define and test the NOT CERTIFIABLE behaviour." / "Ensure the action-floor exclusions are narrow and deterministic, not broad command-pattern exemptions." / "Test log rotation, tier-0 readiness, and all fallback paths." / "No unsupported READY: YES claims."
  - PR sequence A → B → C → D → E approved with branch names `docs/work-003-closeout`, `feature/reviewer-execution-limits`, `feature/work-003-c2-readiness`, `feature/work-003-removals`; item 16 removals in their own PR D; reviewer execution limits (PR B) approved as a small separate change, "procedural limits, not a security sandbox"; keep `docs/work-003-c1-closeout` until PR A is merged and its commit is verified as incorporated. Only PR A is authorised now.
- Spec amended: Status; new section "v0.3.0 scope and C2 design"; Independent review, D5 and Definition of done (CodeRabbit unavailable; Opus, QA and the required CI check are the review process for this repository's PRs and are not external-review evidence); the two illustrative CodeRabbit examples in Scope item 9 made provider-neutral; acceptance criteria for deferred items marked, not removed. Landra's historical CodeRabbit evidence (Scope item 13, Compatibility) and earlier log entries are unchanged.
- Coordinator design proposals recorded for owner approval before C2: the exact-command SHA-256 exclusions and the anchor rule for guard-log evidence (in the new section), and a four-condition trusted-classifier rule (Open decisions). Grounding: Claude Code's `installed_plugins.json` records `installPath`, `version` and `gitCommitSha` per install, and the marketplace clone carries release tags (`v0.2.0` at `b875f32`). This repository has no `.claude/settings.json` pin, so its own development always uses the fallback (tier 2, NOT CERTIFIABLE).

## 2026-10-20: PR B reviewer execution limits (local)
- Owner authorisation (conversation, 2026-10-20): prepare PR B locally on `feature/reviewer-execution-limits` from `main` (`c32076c`): an Execution limits section in `agents/security-reviewer.md` (bounded inputs, isolated scratch probes, no deletes, no running vulnerable base or original versions without explicit authorisation, no retries of declined commands in another form, one simple command per call), the review skill's brief referring to it, regression tests and a 0.3.0 CHANGELOG entry; "procedural instructions, not sandbox enforcement"; Guard and hooks preserved.
- Evidence for the change: the C1 security review (a combined setup-and-probe command denied, 2026-10-19) and the WORK-002 E1 reviewer (an oversized-input run, and a narrower retry after a declined command).
- Exceptions to the limits are valid only when the brief states the owner authorised them for that review. The agent's description and tools are unchanged (always-loaded budget unaffected; still no Edit or Write).
- The local branch `docs/work-003-c1-closeout` (`96a9687`) was deleted with the owner's approval after its patch was verified on `main` as `ac7eb33` (identical `git patch-id`). Git's safe delete refused because a cherry-pick is not an ancestor, so the forced form was used. The remote has no such branch.

## 2026-10-20: PR C (C2 readiness), local
- Design review before implementation (read-only), grounded on disk:
  - Claude Code's `installed_plugins.json` records `installPath`, `version` and `gitCommitSha`.
  - The marketplace clone is a shallow checkout of its pinned tag.
  - All 42 files of tag `v0.2.0` match the installed cache in bytes and modes; the cache's only extras are `.in_use/<pid>`.
  - Landra pins `ref: v0.2.0`.
  - The guard log has one-second timestamps, best-effort writes, rotation at 1 MiB, dropped lines above 2 MiB, and a deadline-killed writer.
- Owner decisions (conversation, 2026-10-20), verbatim excerpts:
  - "Add a third narrow exclusion for the exact `git switch <recorded increment branch>` resume command."
  - "Any logged Guard event after the increment-start anchor raises the action floor to tier 2, except for the precisely defined start, resume and authorised worktree-merge exclusions. Include denials and events from other sessions."
  - "Readiness must execute the full gate itself against the resolved merge-base."
  - "For C2, compute effective tier during readiness evaluation, not after each task commit."
  - "Standalone `/review` without valid increment state and anchor must report NOT CERTIFIABLE and READY: NO."
  - "Accept and document the residual possibility of silent Guard-log write loss."
  - "Verify that the executing plugin root resolves to the selected installed-plugin registry path, and verify the whole installed plugin tree against the matching marketplace tag, ignoring only the known runtime `.in_use/` files."
- Implementation (coordinator, in the main checkout): see Implementation state. The tests use fixture registries, a tagged fixture marketplace clone, an installed copy and projects with local bare remotes, covering:
  - trust failures, each alone;
  - anchors, exact hashes and near-misses, resume, denials, other sessions and worktree merges;
  - rotation, malformed, truncated, linked and oversized logs;
  - missing evidence and stale or failed QA;
  - tier 0 YES without an external reviewer; tier 1 and 2 with and without an external reviewer;
  - the base-commit gate and gate modification;
  - the classifier floor over a state tier of 0;
  - dirty, detached and stateless runs.
- Defects found and fixed during implementation:
  - A parenthesis error in the new schema clause made the state validator fail to compile. Because `validate_state_json` discarded jq errors, every state then validated (two existing schema tests caught it). The clause was fixed, and the validator now reports its own failure as a schema error (fail closed). The latter changes WORK-002 code and is reported as a deviation.
  - The hook-target extraction first split quoted `"$CLAUDE_PROJECT_DIR"/path` into two words; quotes are now removed, not turned into separators.
  - Three test lines needed line-scoped `SC2016` directives.
- Process: the owner declined one Bash command that would have edited the docs with a Python heredoc. The guard flagged its text as a deploy/release class. It was not retried, split or rephrased: the four documentation files were edited with the Edit tool instead, and the diff was checked.
- `GATE full: PASSED (exit 0) command: scripts/check.sh` (3636 passed, 0 failed).

## 2026-10-20: PR C remediation, local
- Internal reviews of `6f24c6c` (Opus security reviewer and QA; internal checks, not external review evidence):
  - Security: 1 High (H1: the base came from the local `origin/<default>` ref, which an unguarded `git update-ref` could move to HEAD, emptying the diff). Medium: M1, the gate ran in a working tree that skip-worktree could hide; M2, records failed open to `{}` and were read after the gate. Six Low.
  - QA: Medium:
    - M1: an unreachable tier-1 security rule;
    - M2: a configured reviewer's failure was ignored at tier 0;
    - M3: the same records fail-open as security M2;
    - M4 and M5: untested cells and weak assertions;
    - M6: the residual-risk instruction lacked `--sha`.

    Five Low.
  - The security reviewer's first command chained read-only commands with `&&`, against its execution limits; it changed nothing and was reported.
- Owner decisions (conversation, 2026-10-20), verbatim excerpts:
  - H1: "Record the default-branch commit when the increment begins. Readiness must detect and reject an unexpected change to the recorded default-branch ref, including moving origin/main to HEAD. … Do not automatically accept a newer ref. Any legitimate re-anchor needs a separate explicit and auditable workflow. Do not modify the Guard in PR C. Do not require live `git ls-remote`; document that remote authenticity is not verified."
  - M1: "Use one validated state snapshot, fail closed on state-read errors, and detect state changes during readiness. Never replace failed reads with `{}` or interpret errors as zero findings."
  - M2: "Fail closed if git status fails or tracked files have skip-worktree/assume-unchanged flags. Prefer running the full gate in a fresh detached scratch worktree at HEAD …". Asked because Landra's committed `full` gate assumes installed `node_modules`; the owner chose option 1: "Implement the fresh local clone at the exact HEAD commit and run the full gate there. Never fall back to the development checkout or link its node_modules, .env or other ignored/untracked files. … Do not modify Landra as part of PR C. Record its gate update as a separate prerequisite for v0.3.0 adoption …"
  - M3: "At tier 0, NOT CONFIGURED is permissible only when all other requirements pass. A configured external review returning BLOCKING or ERROR prevents READY: YES at every tier."
  - M4: "Remove the unreachable tier-1 security-category branch and update the spec, documentation and tests."
  - Also: fix M5, M6, L1–L3, L6 and L8; regression tests for validator failure at load and write; investigate the finding-confirmation fail-open; a real-guard-to-readiness integration test; keep the trust limitations and the conservative action floor; denials never excluded.
- Implemented:
  - **H1:**
    - the base is the recorded `baseSha` (write-once in `workstate.sh`);
    - it must equal the local `origin/<default>`, be an ancestor of HEAD and match the branch's oldest reflog entry;
    - `deliver` records it with the start.
  - **M1:** the spec and state are copied once and `workstate.sh --dir <copy>` reads only the copy. A failed or invalid read is NOT CERTIFIABLE. The live files are hashed again at the end, along with HEAD and the default-branch ref.
  - **M2:**
    - `git status` and `git ls-files -v` must succeed, with no assume-unchanged or skip-worktree flags;
    - staged renames are checked on both paths;
    - the gate runs in a `git clone --no-hardlinks` of the repository at exactly HEAD, with origin removed and hooks off, and is removed afterwards. It never falls back to the checkout.
  - **M3, M4, M5:** as decided; external and gate verdicts count only when the exit status agrees with the verdict line (L2).
  - **L1:** `--no-renames` in the coverage diff.
  - **L3:** hashes must be 64 hexadecimal characters, or the result is NOT CERTIFIABLE.
  - **L6:** ref-like and default-branch names are refused as work or worktree branches.
  - **L8:** the docs listed above.
- Defects found while testing the remediation (the first two full runs: 119, then 51 failures):
  - The index-flag check matched `[a-z]`. In this locale's collation that range also matches capitals, so every ordinary `H` entry from `git ls-files -v` read as assume-unchanged. It now uses `[[:lower:]]`.
  - Every gate in the clone was refused with `git-lookup-failed`, for two reasons:
    - readiness exported `GIT_NO_REPLACE_OBJECTS`, which the guard treats as a Git-redirecting variable;
    - the clone's path contained `checkout`, which makes the guard look Git state up.

    A detached HEAD would also fail the guard's branch lookup. The owner declined one diagnostic Bash command, a chained scratch reproduction with a push to a scratch bare repository's `main`. It was not retried, split or rephrased. The cause was then found by reading `guard-bash.sh` and `guard/hook-git.sh`.
  - Owner-approved fix, in `readiness.sh` only:
    - the gate and external review run without the two variables, while readiness's own reads keep them;
    - the clone is checked out on its own branch `ai-engineering-readiness-gate`, with every other branch removed;
    - the clone directory is named `gate-tree`;
    - a repository with replace refs is NOT CERTIFIABLE.

    The guard is unchanged. Tests: a temporary path containing `checkout` and `push`; a gate that checks its environment, branch, refs, remote and HEAD from inside; a replace ref; and a guard-refused unsafe gate in the clone.
- The finding-confirmation fail-open (`workstate.sh` `holds`): confirmed by reading. A jq error made `holds` return false, so `finding-invalid` would accept a security finding without `--confirmed-by`. It needs a fix, and it is fixed: `holds` now treats a jq error (exit 2, 3 or 5) as an internal error that stops the command. This changes WORK-002 code (a deviation).
- Not fixed (not in the approved list): security L4 (hook-target extraction misses newline separators and non-hook command settings) and L5 (events logged in other repositories or outside Git; only noted as a residual in the readiness header), QA L2 (jq error text on oddly shaped registry files) and QA L3 (the gate and external review still run on a NOT CERTIFIABLE evaluation).
- Committed as `61cda34`. `GATE full: PASSED (exit 0) command: scripts/check.sh` (3855 passed, 0 failed).

## 2026-10-20: PR C remediation round 2, local
- Fresh internal reviews of `a5e7796..61cda34` (not external review evidence):
  - Security: High H-1, the base could still be chosen. Path B: a ref planted with an unguarded `git update-ref` before the start command. Path A: a base recorded late after recreating the branch. Medium M-1: the external reviewer could be shown a falsified diff through repository config or `GIT_EXTERNAL_DIFF`. Medium M-2: the gate ran before checks it could undermine. Low: a guard-log rotation race, an empty-id trigger-2 decision, test gaps.
  - QA: no High. Medium: no pinned-locale test, stale `docs/architecture.md:116`, no recovery from a moved default-branch ref, reflog expiry, undocumented `origin/HEAD`. Plus Low items and missing negative tests.
- Owner decisions (conversation, 2026-10-20), verbatim excerpts:
  - "H1: Use options (a) + (b). Require a full 40-character base SHA at increment creation, verified against the expected default-branch ref at that moment. Make that exact SHA visible in the owner-approved increment-start command. The recorded base must be immutable for that increment. Reject late base recording, branch-renaming attempts to substitute a base, and unexpected default-branch ref changes."
  - "Before changing the start command, inspect its compatibility with the existing Guard classification and the exact-command action-floor exclusion. If implementing this requires a Guard policy change or creates a new approval bypass, stop and report the blocker."
  - "Document that owner visibility is not independent authentication of the remote SHA."
  - "External review: Run it against a separate fresh clone at the exact intended HEAD, using controlled Git environment and configuration. … Reject unsafe diff/textconv configuration rather than trusting repository-controlled diff behaviour."
  - "Gate ordering: Separate the gate clone from readiness's temporary evidence files. Run trust and external-review checks before the gate, then revalidate … A changed or unreadable critical input must result in NOT CERTIFIABLE and READY: NO. Never reuse a stale successful verdict."
  - Fix the remaining QA correctness and documentation findings, add the listed tests, and pin a predictable locale.
- Compatibility check (read-only, `guard/policy.jq:644-648`):
  - `git switch -c <branch> <full sha>` has one start-point operand, so the guard classifies it as `git switch -c <start point>`. That is the same `ask` as the earlier `origin/<default>` form; it is logged with the exact command's hash, and the owner sees the full commit.
  - No Guard change is needed. The exclusion matches only that exact text with the recorded base, so it opens no bypass: `-C`, other start points and denials still raise the floor.
- Implemented:
  - **H1:**
    - planned to active requires a full `--base-sha`, checked against `origin/<default>` in the repository holding the specs directory;
    - a base is never recorded later or changed;
    - the anchor is `git switch -c <branch> <recorded base>`.

    "Increment creation" is implemented as the planned-to-active start, when the branch is created, not `increment-add` at planning time.
  - **External review:** runs in its own clone. Inherited Git overrides (the `GIT_CONFIG_*` family, `GIT_EXTERNAL_DIFF`, `GIT_ATTR_SOURCE` and more) are unset for readiness and its children. Diff-reshaping configuration in any scope, and a non-empty `.git/info/attributes`, are NOT CERTIFIABLE.
  - **Ordering:**
    - separate temporary roots for readiness's files and each clone;
    - the external review runs before the gate;
    - gate and reviewer output are held in memory;
    - after the gate, readiness revalidates the state and spec, HEAD, the branch, `origin/<default>`, replace refs, diff configuration, the installed plugin (the trust check re-run) and the evidence statuses.
  - **Guard log:** the newer file is read first, then the rotated one, and both must be the same files (inode) afterwards. Trigger-2 decisions are counted, not looked up by id.
  - **Locale:** readiness runs with `LC_ALL=C`; the gate and the reviewer get the caller's locale back. `git status` runs with fsmonitor and the untracked cache off.
  - **Clones:** created with an explicit remote name (`clone.defaultRemoteName` cannot break it), and alternates are refused.
- Tests added:
  - H1 paths A and B: no anchor without the base in the start command, a recreated branch, a late base, short and wrong bases, and the planted-ref residual made explicit;
  - external review receiving the intended base and HEAD, and its diff manipulation (`GIT_EXTERNAL_DIFF`, `diff.external`, textconv, `info/attributes`);
  - gate tampering: replace ref, moved ref, edited install, diff config, rewritten state, and run-gate killed (no verdict);
  - guard-log rotation during the read (a stand-in `cat`), an empty-id trigger-2 decision, missing QA, unreadable and linked logs, clone failure (a stand-in `git`), external ERROR at tier 2, and the locale.
- Test defects found while running:
  - an existing WORK-002 skill test still expected the old start command;
  - the first "no verdict" gate action used `pkill`, which matched nothing.

  Its replacement walked up the process ancestry and killed the outermost `run-gate.sh full`. When the suite ran inside the real full gate, that was the real gate run: it was killed (exit 137), and nothing else was affected. The action now stops at `readiness.sh` and matches only a `run-gate.sh` on readiness's `/gate-tree` clone.
- `GATE full: PASSED (exit 0) command: scripts/check.sh` (3966 passed, 0 failed). Committed as `429aae3`.

## 2026-10-20: PR C remediation round 3, local
- Fresh internal reviews of `a5e7796..429aae3` (not external review evidence):
  - **Security, High:**
    - H-1: user-level filters and attributes (`~/.config/git/attributes`, `init.templateDir`) altered the gate clone's checkout, so a failing gate reported PASSED;
    - H-2: a user-level `core.bigFileThreshold`, attributes or diff prefixes blinded the reviewer.

    Both were reproduced in an isolated scratch HOME, and every command involved gets no Guard decision.
  - **Security, Medium:**
    - M-1: a committed `.gitattributes` could hide changes from the reviewer;
    - M-2: the anchor proves a start was asked, not approved: a rejected start can still be followed by unguarded branch creation;
    - M-3: a gate could rewrite the running `readiness.sh` (bash reads scripts lazily).
  - **Security, Low:** further inherited variables, and a locale test that could not fail.
  - **QA:**
    - High: no time bound;
    - Medium: cost, recovery from a moved ref, user-level configuration, the planted-ref test never running readiness, untested cells, test hermeticity, documentation mismatches;
    - one timing-test failure in QA's run.
- Owner decisions (conversation, 2026-10-20), verbatim excerpts:
  - "Verify scratch checkout contents byte-for-byte against the intended HEAD before executing the gate or reviewer. Neutralise inherited Git diff/filter/template configuration in the scratch clones, including relevant HOME/XDG settings, without exporting Guard-conflicting variables into Guard-classified child commands. Reject effective attributes or configuration that can hide or transform changed files."
  - "Neutralise user-level diff.external and similar settings when safe … If an unsafe effective setting cannot be reliably neutralised, fail closed."
  - "Wrap readiness execution in a main() structure … defence in depth, not protection against a determined hostile gate."
  - "Add bounded execution: 30-minute full-gate timeout, 15-minute external-review timeout, and 50-minute overall readiness limit. … A timeout or missing verdict is a failure. Clean up scratch resources on normal exit and handled termination."
  - "Skip gate and external review when readiness is already NOT CERTIFIABLE. Defer a separate assess mode."
  - "Investigate the one QA timing-test failure separately. Do not assume it was caused by parallel reviews."
  - "An ask event does not prove owner approval or command execution. … Identify the exact additional Guard evidence or protocol required to close this gap, but do not implement it without separate approval. Explicitly report whether READY: YES remains reachable and under what assumptions."
- Implemented:
  - **Clones:**
    - clone and checkout use controlled Git: `HOME`, `XDG_CONFIG_HOME` and a template set to empty readiness-owned directories, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM`, `GIT_ATTR_NOSYSTEM`, `GIT_ATTR_SOURCE` set to the empty tree, attributes file `/dev/null`, hooks off, `core.autocrlf=false`;
    - these variables are given only to readiness's own Git commands, never to the gate or the reviewer;
    - every tracked blob and mode is verified, and nothing may be untracked or ignored.
  - **Neutralised in each clone's local configuration:**
    - `core.attributesFile=/dev/null` (this also covers the XDG default) and `core.bigFileThreshold`;
    - the diff prefixes, `noprefix`, `mnemonicPrefix`, `relative` and `ignoreSubmodules`;
    - hooks and fsmonitor.
  - **Refused (fail closed):**
    - an effective `diff.external`: a scratch probe showed an empty local value makes `git diff` fail ("cannot run"), so it cannot be neutralised;
    - a changed text file with `-diff`, `binary`, or a diff driver that has `textconv`, `command` or `binary` configured;
    - any changed file with a configured filter driver.

    These are evaluated in the reviewer's own environment with `git check-attr`, so committed and system attributes are included. The development repository's own diff configuration is no longer rejected: it doesn't reach the clones.
  - **`main()`:** the whole script is one function, called on the last line.
  - **Time limits:**
    - `run_bounded` runs each child in its own process group, with a TERM-then-KILL watchdog, and keeps the child's exit status;
    - the limits are 30, 15 and 50 minutes, and callers can lower them but not raise them;
    - INT, TERM and HUP stop the active child and exit 4, and the EXIT trap removes every temporary root;
    - progress lines go to stderr, and the review skill runs readiness in the background and waits for it.
  - **Skipping:** the external review and the gate don't run once readiness is NOT CERTIFIABLE.
  - **Tests:**
    - the hermetic test home (`HOME`/`XDG_CONFIG_HOME` fixtures, Git redirect variables unset);
    - both reproduced bypasses, with filter and template variants for the gate, and four blinding variants plus `diff.external`, textconv and committed attributes for the reviewer;
    - `GIT_TEMPLATE_DIR`, and the gate rewriting the running script in place;
    - timeouts for the gate, the reviewer and the overall limit, TERM cleanup, and skipping;
    - the missing negative cells, readiness on a planted base (recording the open gap), environment exit 2;
    - a locale test that can fail, and skipped preconditions reported as SKIP rather than pass.
  - **Defect found by the first full gate of this round:** a gate stopped by its time limit left `run-gate.sh`'s own temporary file behind, because TERM skips its EXIT trap. Each child now gets a private `TMPDIR` inside its clone root, which readiness removes; this also cleans up the gate's own temporary files. A test asserts the gate's `TMPDIR`.
  - `GATE full: PASSED (exit 0) command: scripts/check.sh` (4079 passed, 0 failed, 0 skipped).
- **Timing test (`tests/run.sh` guard-log deadline) investigation:**
  - A scratch replica (same guard script, stalled-Git stand-in and timing method) ran 70 times idle and 40 times under 12-CPU load. Every run that did not overlap a system sleep took 2.1–2.3 s, against the test's 4 s bound.
  - Three outliers (29.7 s, 61 s, 1037 s) each coincide exactly with a macOS sleep in `pmset -g log` (22:55:00–22:55:30, 61 s and 1040 s).
  - QA's 6 s result could not be tied to a specific sleep because its time is unknown. The test measures wall time across any sleep or suspension; no Guard defect or load sensitivity was reproduced.
  - The timeout is unchanged. Recommendation: treat a lone failure as environmental and re-run, or later measure with a sleep-independent clock (a separate change).
- **READY: YES remains reachable under these assumptions:**
  - (A1) the installed plugin's local consistency check is not defeated by a local process (accepted);
  - (A2) the guard log, state and evidence are not edited directly (accepted; workflow records);
  - (A3) `origin/<default>` named the remote's commit when the increment started. Nothing proves this: the `ask` anchor shows the start command was asked, not approved or executed, and remote authenticity is not verified. The owner accepted "remote authenticity is not verified" in the H1 decision, but the owner-visibility mitigation previously claimed for it is withdrawn;
  - (A4) the gate is not deliberately hostile (revalidation is defence in depth).

  If A3 is not acceptable without evidence, readiness must fail closed (no READY: YES) until the guard change below exists. That is an owner decision; this round leaves READY: YES reachable under A3.
- **Proposed separate guard change** (not implemented; it needs approval because it changes the guard and hooks):
  1. Execution evidence: a `PostToolUse` hook for Bash appends `{event: "executed", toolUseId, sessionId, commandSha256, exit status}`, and the existing `PreToolUse` `ask` line gains `toolUseId`. Claude Code runs `PostToolUse` only for a tool call that was permitted and ran, so readiness could require the anchor `ask` and a successful `executed` record with the same `toolUseId` and hash. A rejected start produces no `executed` record. Whether the hook input carries a tool-use id must be verified against Claude Code's hook documentation first.
  2. Approval evidence: an `executed` record shows permission was granted, but under an auto-approving permission mode it would not show a human decision. If Claude Code exposes the permission decision to hooks, record it; otherwise require the owner's `/ai-engineering:deliver` command to record the start (an owner-command record, itself a workflow record).
  3. Base authenticity: at activation, record the remote's default-branch commit with one `git ls-remote origin refs/heads/<default>` (or the authenticated `gh api` compare), and refuse activation or certification when it differs from the base. This reverses the earlier "no ls-remote" decision, for the start only.
  4. Ref protection: the guard asks for writes to `refs/remotes/*` (`update-ref`, `fetch` refspecs into `refs/remotes`, `remote set-head`, `symbolic-ref`) and for `git branch -f/-m` of the increment branch, so tampering after the anchor raises the floor.

  With 1 and 3, A3 would rest on recorded execution and a remote check instead of an unproven assumption. Direct edits of the local log files remain the accepted A2 residual.

## 2026-10-21: PR C remediation round 4, local
- Fresh internal reviews of `a5e7796..74c72a2` (Opus security and QA; internal checks, not external review evidence):
  - security: three Medium (binary files hidden from reviewers, submodule bumps hidden by ignore settings, readiness's own tools controllable through `BASH_ENV`, functions and `PATH`) and five Low;
  - QA: one High (review checks ran with no reviewer configured), nine Medium (leaked watchdog, a vacuous termination test, untested cells, the timing conclusion, unbounded output, clone diagnostics, suite runtime, a flaky limit test, stale wording) and Lows.
  - Three leaked watchdog process groups from the termination test were stopped by the coordinator and checked gone.
- Owner decisions (2026-10-21), verbatim excerpts:
  - "When the trusted base-commit configuration explicitly has externalReview: null, skip the external-review clone and its diff checks. This exception applies only to tier 0. Missing, malformed or untrusted configuration must fail closed."
  - "Implement a narrow allowlist defined at the trusted base commit for non-executable assets such as images and fonts. … Reject unsafe patterns and branch-controlled allowlist changes."
  - "Until the separate Guard trust-boundary protocol is approved and implemented, fail closed for READY: YES where owner-approved base provenance is required. Add an explicit base-provenance status to the READINESS block."
  - "Keep the complete existing gate. Defer splitting out a faster subset."
  - "Fix the leaked watchdog and process-group termination. … Do not run another full suite until the focused termination test passes."
  - Items 6–11: environment hardening, submodules, bounded output and diagnostics, clone and temporary-directory hardening, missing tests and wording, and the timing-test history.
  - On the timing investigation (after declining a replica with a load generator): "Please use read-only inspection first … Do not run another stress test until I approve its design."
- Implemented (readiness.sh unless noted):
  - **Base provenance:** `BASE PROVENANCE: UNVERIFIED` on every run, and READY: NO for that reason alone. No workflow reaches READY: YES; exit 0 is unreachable until the guard change is approved and built.
  - **External review:** at effective tier 0 with `externalReview` explicitly null in a valid base `.agents/gates.json`, no review clone and no diff checks. A missing file or key doesn't skip them; a malformed or oversized file is NOT CERTIFIABLE.
  - **Binary files:** allowlist `binaryAssets` (relative directories ending in `/`, no `..` or hidden segment, at most 32) read only from the base commit. Allowed files must be `100644`, an image or font extension, and match that format's leading bytes. Every changed binary is reported with its status, size and SHA-256. A branch that changes the list is NOT CERTIFIABLE (literal reading of "reject branch-controlled allowlist changes": the list changes only in its own owner-reviewed change).
  - **Watchdog:** the watchdog runs inside the child's process group, ignoring TERM. Readiness signals the group only while the watchdog is alive (before its `.final` marker), so a signal never reaches a reused process-group id. The group, watchdog included, is killed when the child ends and on a handled signal.
  - **Environment:** `#!/bin/bash -p`, plus one restart without `BASH_ENV`, `ENV`, exported functions, `LD_PRELOAD`, `LD_AUDIT` or `DYLD_INSERT_LIBRARIES`. Tools come from fixed system directories. Every `GIT_*` variable is removed. Library-path and Perl variables are removed for readiness's own tools. `jq` and the helper scripts get an empty `HOME`.
    - `run-gate.sh` and `external-review.sh` get the controlled tools and an empty `HOME`; only their configured command gets the caller's `PATH` and `HOME` (`AI_ENGINEERING_COMMAND_PATH`/`_HOME`).
    - No Guard-conflicting variable is exported to them; the real-guard and gate tests still pass.
  - **Submodules:** evidence coverage and the review checks use `--ignore-submodules=none`. Each `.gitmodules` submodule's `ignore` is overridden to `none` in the review clone. A changed path missing from the reviewer's own `git diff --name-only` is NOT CERTIFIABLE.
  - **Output and diagnostics:** readiness reads at most the last MiB of gate output and 4 KiB for the reviewer's verdict lines. A failed clone or checkout reports Git's last line.
  - **Clones:** `--no-local --single-branch --branch <increment branch> --no-tags`, `transfer.fsckObjects`, and `safe.directory` for the repository readiness already read.
    - Readiness's own reads use no commit-graph.
    - A grafts file and non-empty `info/attributes` are NOT CERTIFIABLE.
    - `TMPDIR` is resolved to its real path and must be outside the repository and the main worktree (exit 2).
    - Tracked paths starting with `"` or holding CR or LF, and symbolic links that are absolute or leave the repository, are NOT CERTIFIABLE.
  - **Tests:**
    - stand-in tests moved to trusted variant installs (readiness no longer takes tools from `PATH`);
    - the overall limit tested deterministically (a reviewer taking 3 s before the gate; a slow stand-in Git before the review);
    - termination with TERM, INT and HUP proves that the gate's shell and child stopped and that no watchdog survived;
    - plus the binary, submodule, visibility, byte-mismatch, filter and driver-key, reviewer TMPDIR, environment-injection and TMPDIR cells.
  - **Docs:** architecture, consuming project, external review, README, review and deliver skills, CHANGELOG, spec (stale status and approval wording fixed).
- **Defect found by the focused run:** `env -u … LC_ALL=POSIX -u …` stops parsing options at the first assignment, so a caller with `LC_ALL` set broke the gate's environment. Every `-u` now comes before the assignments; the locale test caught it.
- **Timing test (`tests/run.sh` "guard log deadline"), read-only:**
  - Two different failures are on record: "the stalled git shim never ran" (C1 era) and a 6 s hook (QA, round 3).
  - In `guard/hook-git.sh` the 5 s Git budget runs from hook start (`hook_git_started_at`), so a hook that is slow before it logs skips the Git call entirely. A 2 s log deadline that expires before the shim's first line has the same effect.
  - The test measures wall-clock time (`SECONDS`), including sleep or suspension.
  - Both failures are consistent with a slow or suspended hook; neither is proven, and the current test can't tell the phases apart.
  - A bounded single-run regression design was proposed to the owner (inert command, no detached watchdog or delayed group signal, reaps its child, distinguishes a slow guard from a shim that never started). Not implemented; the timeout is unchanged.

## 2026-10-21: PR C remediation round 5, local
- Fresh internal reviews of `a5e7796..c095c86` (internal checks, not external review evidence) found: QA High, the round 4 watchdog-survivor checks were vacuous on macOS (`awk -v` with a newline fails there, so they always passed; the round 4 entry's "no watchdog survived" was proven only by manual `ps` checks); security Medium, gate output and unfiltered values (paths, guard-log fields, record ids) could print forged `READY:` or `CERTIFIABLE:` lines into the block; and Mediums and Lows on tool resolution, Git versions, the binary check's cost, TMPDIR case on case-insensitive disks, and environment gaps.
- Owner decision (2026-10-21), verbatim excerpt: "First fix and verify the watchdog termination test, then address the forged READINESS output, environment hardening, TMPDIR containment, tool resolution, Git version handling, bounded binary checks and material remaining safety issues. Keep READY: YES fail-closed pending the separate base-provenance protocol."
- Implemented:
  - **Termination test:** one exact command line per `awk` call; a `ps` or `awk` failure counts as a leftover; a control process proves the check sees a running process; bounded waits (a stuck run is killed and fails, never hangs the suite); 3 s windows instead of 1 s; a new cell sends TERM during a clone and proves no process of the clone's process group remains (listed by group, never signalled by the test).
  - **Output:** every block line goes through `block_line` (control characters shown as `?`); gate output is quoted with `  | `; the review skill and docs say the verdict is the final `READY:` line with the exit code. Tests: a gate printing `READY: YES`, an untracked name with newlines, a guard-log session id with a newline.
  - **Environment:** the restart also removes `SHELLOPTS`, `BASHOPTS` (bash re-exports an inherited `SHELLOPTS`), `GCONV_PATH`, the library-path and Perl variables. Their values travel as `AI_ENGINEERING_COMMAND_SAVED_<name>`, which only `run-gate.sh` and `external-review.sh` read, for the configured command alone; the plugin scripts and readiness's review-diff checks now run without them and with `LC_ALL=C`.
  - **TMPDIR:** each directory from TMPDIR up to `/` is compared with the repository and main worktree by device and inode (`-ef`).
  - **Tools and Git:** the exit-2 message and docs name the trusted directories; Git older than 2.40 is exit 2 with its version.
  - **Binary files:** one linear pass over `--numstat` and `--raw` side by side; more than 200 changed binaries is NOT CERTIFIABLE before any is read; the overall time limit is checked per file.
  - **Other:** symbolic links with `..` after a name are refused (a name could itself be a link); cleanup removes a top-level link without following it; after the first signal further INT, TERM and HUP are ignored until cleanup ends; the child's group is tracked immediately after it starts; reviewer lines cut to 400 characters; "ask(s)" wording; `commit_files` no longer re-adds removed paths.
- Kept as documented residuals: the raw child output in readiness's temporary directory is not size-limited (the gate can fill the disk in other ways); the leading-byte check identifies a format but doesn't validate the file; the TERM-to-KILL grace ends when the command itself ends.
- **Proposed Guard trust-boundary protocol** (not implemented; it changes the guard and hooks, so it needs separate approval):
  1. Verify first, against Claude Code's hook documentation, which fields `PreToolUse` and `PostToolUse` inputs carry (a tool-use id and the permission mode are assumed below).
  2. Correlated execution: the anchor `ask` record gains the tool-use id; a new `PostToolUse` Bash hook appends `{event: "executed", toolUseId, commandSha256}` only for the exact start command. Readiness requires an `ask` and an `executed` record with the same id and hash; a declined start has none.
  3. Owner approval: the `executed` record also stores the permission mode. A mode that approves without a human prompt (auto or bypass) never counts as owner-approved; then the base stays UNVERIFIED.
  4. Remote authenticity: the same `PostToolUse` hook records `git ls-remote origin refs/heads/<default>` (bounded, a few seconds); readiness requires it to equal the recorded base. A failed or timed-out lookup leaves it UNVERIFIED.
  5. Ref protection: the guard asks for writes to `refs/remotes/*` and for forced moves or renames of the increment branch, so tampering after the anchor raises the floor.
  6. Readiness reports `BASE PROVENANCE: VERIFIED` only when 2–4 hold; otherwise UNVERIFIED and READY: NO, as now. Direct edits of the local log remain the accepted A2 residual.
- **Gate runs:** the first full gate failed one test, "guard log deadline: the hook took 5 s" (4308 passed, 1 failed), with no Guard, hook or settings change in the diff and no system sleep in `pmset -g log` for that window. This contradicts round 4's working explanation (system sleep) as the only cause: a 5 s hook without sleep happened. The cause is still unknown; the timeout is unchanged and the bounded regression design still awaits approval. The second run passed: 4309 passed, 0 failed, 0 skipped.

## 2026-10-21: PR C remediation round 6, local
- Internal reviews of `a5e7796..1ef3b0c` (internal checks, not external review evidence):
  - QA: one Medium (the INT termination test fails when the suite runs as a background job, because a signal ignored at shell start can't be trapped) and one Low (doc drift).
  - Security: two Medium (a symbolic link escape through pattern expansion of a directory named `*`; `GREP_OPTIONS` reaching readiness's and the classifier's greps) and three Low (cleanup messages after the block; Unicode line separators and bidirectional controls; TMPDIR in a sibling worktree or superproject, `POSIXLY_CORRECT`, `git --version` before the `GIT_*` removal).
- Read-only finding reported to the owner before any change: with `GREP_OPTIONS=-F` (or `--exclude=*`, or an invalid option), the classifier's `grep -q '^CAP$'` misses the path cap. The entries past the cap are never classified, the stray `CAP` line becomes a tier-1 entry, and the result is exit 0, `error: null`, floor 1 instead of 2. Readiness passed the caller's `GREP_OPTIONS` and cap overrides through.
- Owner decision (2026-10-21), verbatim excerpts: "Prefer explicit, checked scanner status over marker greps." "Validate resolved containment rather than relying solely on lexical depth." "Complete cleanup before emitting that result, report cleanup failures conservatively, and escape control characters including Unicode line separators and bidirectional controls." "Defer a wholesale env -i allowlist redesign. Document remaining environment assumptions instead of claiming complete isolation."
- Implemented:
  - **Classifier:** the awk scanners report through exit statuses (0 complete, 10 cap, 11 malformed); every other status, a failing `tr`, an empty result from non-empty Git output, or `-z` output without its final NUL fails closed. No grep remains. `GREP_OPTIONS`, `GREP_COLOR` and `GREP_COLORS` are unset, and the Git variable removal now precedes `git --version`.
  - **Readiness environment:** the restart also drops `GREP_OPTIONS`, `GREP_COLOR`, `GREP_COLORS` and `POSIXLY_CORRECT`; a top-level restart before `main` is parsed handles `POSIXLY_CORRECT`. The classifier cap overrides are unset. Every `GIT_*` variable is removed before the first Git command. Readiness itself no longer uses grep (an awk count with `pipefail` and a numeric check; an in-shell membership test; awk for the clone diagnostic). The remaining deny-list assumption is documented.
  - **Links:** paths and targets are split with `read`, never by an unquoted expansion; a target holding a control character, or whose text differs from the blob (NUL bytes, trailing newlines, over 4096 bytes), is refused. In each clone every link is followed physically (`cd -P`, at most 40 links) and must end inside the clone in an existing directory.
  - **TMPDIR:** also refused inside any worktree listed by `git worktree list --porcelain -z` and inside the working trees of enclosing superprojects.
  - **Output:** cleanup runs before the block; `rm` messages are discarded and each root is checked to be gone; a leftover is NOT CERTIFIABLE; signals are ignored from the start of the report; records are read before cleanup; `block_line` and the gate-output quoting replace every byte outside ASCII.
  - **Tests:** classifier caps under `GREP_OPTIONS` `-F`, `--exclude=*` and `-v`; malformed raw output (bad prefix, truncation, missing final NUL, only NULs) and numstat; a failing raw, numstat and SQL scanner. Readiness: `*` and `[ab]` directories, an escaping chain, a control-character and an inexact target, the clone resolver on real links (escape, chain, through a directory link, absolute, dangling directory, loop); `GREP_OPTIONS` against the `-diff` check and the binary count; caller caps; `GIT_TRACE`; sibling worktree and superproject TMPDIR; Unicode in gate output and a binary path; an immutable leftover whose name holds a newline and `READY: YES` (macOS `chflags`).
  - The round-5 QA fixes are kept (a SIGINT ignored at start, cleanup after a failed leftover check, doc drift).
- Verified: the new classifier cells fail against the round-5 classifier (14 failures, as QA also measured, including the fail-open floor 1); the old link check accepts `*/x/link -> ../../../outside` from a root with several entries, the new one refuses it. Focused runs: classifier 605 passed, 0 failed; readiness 906 passed, 0 failed, 0 skipped, also with SIGINT ignored from the start, and no leftover processes.
- Residuals: the environment removal is a named list (other tool variables pass through); worktrees of a superproject other than its main one are not checked for TMPDIR; non-ASCII names are shown as `?`, so two names that differ only there look alike in the block; the resolver has no fixture that passes the lexical rule and still escapes, so it is tested directly on real links. READY: YES stays unreachable (BASE PROVENANCE: UNVERIFIED).
- Fresh internal reviews of `a5e7796..b84c3d9` (internal checks, not external review evidence): QA found all eight requirements met, with Lows only (the failure count above; the immutable-leftover test is skipped where `chflags` is missing). Security confirmed READY: YES unreachable and the round-6 fixes holding, and found two Lows: the tree scan's `tr` status was not checked (a failing `tr` lost `tier2:plugin-code` and case collisions, exit 0, `error: null`), fixed with a regression test in the follow-up commit; and a TMPDIR inside an unrelated enclosing repository's working tree (a nested checkout that is not a submodule) is accepted. The second is left for the owner: refusing any TMPDIR inside a Git working tree would also refuse one under a home directory kept in Git. Full gate on `b84c3d9`: 4400 passed, 0 failed, 0 skipped (878 s).

## 2026-10-22: PR C close-out decisions, local
- Owner decisions (2026-10-22), verbatim excerpts: "Accept the unrelated outer-repository TMPDIR finding as a documented Low residual. Do not introduce a blanket ban on TMPDIR inside any Git repository." "Verify that scratch creation and cleanup cannot alter the unrelated repository outside the dedicated scratch directory." "The separate Guard trust-boundary protocol is approved for design and review only, not implementation." "Keep BASE PROVENANCE: UNVERIFIED and READY: NO." "Correct documentation that overstates trust in user-writable tool directories."
- Verified (code and an executed test): readiness creates only its own `mktemp` roots under TMPDIR, runs every Git command in the repository or in a clone holding its own `.git` (never from the `tmp/` or `home/` roots), and removes the roots; `remove_tree` is limited to those roots and follows no links. The new test runs readiness with TMPDIR inside an unrelated outer repository and checks the outer repository's refs, HEAD, local configuration, file list, modification times outside `tmp/`, status and an empty `tmp/` afterwards. A Git command that the gate or reviewer runs from its TMPDIR or HOME there would find the outer repository; that is documented with the residual.
- Docs: the fixed tool directories stop PATH substitution only (the Homebrew and `/usr/local` ones are usually user-writable); trust checks are local consistency, not authenticated provenance; the TMPDIR residual.
- Design only: `.agents/specs/active/WORK-003-base-provenance-proposal.md` (evidence format, approval and execution binding, threat model, failure behaviour, regression tests). Hook input fields were checked against Claude Code's hooks documentation; three behaviours (V1–V3) are still to be verified before any implementation.

## 2026-10-22: S-L1/S-L2 pipeline status fix and proposal revision, local
- Owner decisions (2026-10-22), verbatim excerpts: "APPROVED: one narrow, local fix for S-L1 and S-L2." "Empty, malformed, incomplete or unreadable results must fail closed, not silently reduce classification or pass readiness checks." "Prefer local, explicit status checks where practical." "NOT APPROVED: implementing or enabling the Guard protocol." "Until verified, no permission mode counts as authenticated human approval."
- The security reviewer's declined scratch setup (two commits in an empty scratch repository and one stand-in `head`) was not retried. The finding it targeted was confirmed by reading the code, and the regressions use the suite's own fixtures.
- **Classifier:** `measure_size` replaces every `wc -c | tr` size (a failing or non-numeric `wc` fails closed). The `head` status is checked on the gates.json, settings.json, raw and numstat reads. An empty base gates.json or settings.json is refused. The reserved-byte `tr` status is checked. Every program write (`cat` heredocs), the built-in rules and the rules join are checked. No global `pipefail`.
- **Readiness:**
  - the worktree listing checks `git` and `tr`, and an empty listing exits 2;
  - the settings, marketplace and gates reads check `git` and `head`;
  - trust checks each `find`, `sed` and `sort`, requires non-empty sorted lists, and compares them with `cmp`;
  - `file_identity` returns `unreadable` unless `ls` and `awk` give a number;
  - the guard-log sizes use `byte_count`;
  - the reviewer-visibility comparison checks each `tr`, `sort`, `comm` and `head`;
  - an unreadable or malformed gates.json at HEAD is NOT CERTIFIABLE (it was read as an empty binaryAssets list).
- **Tests:** classifier stand-ins:
  - `head` on the raw, numstat, gates and settings reads;
  - a failing and a non-numeric `wc`;
  - the reserved-byte `tr`;
  - `cat` writing a program and joining the rules.

  Readiness variant installs:
  - `find` (listing and links), `sort` (trust and reviewer), `comm`, `ls`, `wc` on the guard log, and `head` on bounded JSON, each NOT CERTIFIABLE;
  - a failing worktree `tr`, which exits 2;
  - the reviewer fixture without stand-ins, still READY: NO for base provenance alone.

  Against the `788480f` classifier, 11 of the new classifier cells fail. One of them is a tier-2 change reported as tier 0 when `head` or `wc` fails.
- Proposal revised (design only): JSONL records are telemetry; the necessary conditions are kept but are not sufficient. D1 is an owner-signed start approval (ADR-0004/WORK-004, blocked on G1). D2 is a remote identity pinned at the base, with no network check in the certification path (recommended). D3 is the permission-source inventory. V1–V3 were investigated in the documentation only.

## 2026-10-22: PR C final follow-up (L1, test gaps), local
- Owner decision (2026-10-22), verbatim excerpt: "Approved: one final narrow PR C follow-up on da24ed4." "Do not automatically start another hardening round for Low or informational findings."
- **L1:** base `.agents/gates.json` and `.claude/settings.json` must hold exactly one JSON object.
  - The classifier checks this with `require_one_json_object` (`jq -e -s`).
  - Readiness's `bounded_json_file` does the same. Every caller (registry, known marketplaces, plugin.json, settings.json, marketplace.json, gates.json) expects an object.
  - Absent files keep their meaning.
  - Against the `da24ed4` classifier, a whitespace-only or two-document base file classified with exit 0, `error: null`, at floor 1 or 2.
- **Tests added for the five gaps:**
  - empty, whitespace, two-document, array and malformed base config (classifier and readiness);
  - a 3 MiB base gates.json, which reports "too large", not a read failure;
  - a malformed gates.json at HEAD;
  - the `head` failure, now asserting the settings, base gates and HEAD gates reasons, plus a marketplace-only `head` failure;
  - a failing `tr` in the reviewer comparison.
- **Proposal:** the D3 inventory now lists command-line flags and prompt-tool and embedding hosts. A diagnostic SSH check uses `ssh -F /dev/null`.
