# Architecture (v0.2)

The system is a Claude Code plugin, `ai-engineering`, published from this repository's marketplace. It prefers native Claude Code mechanisms over custom orchestration. Decision records: [ADR-0001](decisions/ADR-0001-claude-native-architecture.md) and [ADR-0002](decisions/ADR-0002-gate-execution-trust-boundary.md).

## Components

| Concept | Component | Notes |
| :- | :- | :- |
| Planning / Spec | Main session + `plan` skill | Not a subagent: planning needs conversation with the human. |
| Orchestrator | Main session + `deliver` skill | Coordinates; does not own architecture. |
| Platform design | Main session + `platform-standards` | Conversational; approval recorded as ADR/spec. |
| Frontend | `agents/frontend.md` | Preloads engineering + frontend standards. |
| Backend | `agents/backend.md` | Preloads engineering + security standards. |
| Platform implementation | `agents/platform.md` | Stops at a reviewed plan; never applies. |
| Security | `agents/security-reviewer.md` | No Edit/Write tools; see [Reviewer isolation](#reviewer-isolation). |
| QA | `agents/qa.md` | No Edit/Write tools; see [Reviewer isolation](#reviewer-isolation). |
| Learning | `agents/learning.md` | Writes limited to `.agents/` by hook. |
| Independent review | `review` skill + `scripts/external-review.sh` | Provider-neutral contract: [external-review.md](external-review.md). |

Each agent's model and tools are defined only in its frontmatter (`scripts/check.sh` prints the routing).

Skills: `engineering-standards`, `security-standards`, `frontend-standards`, `platform-standards`, `playbooks` (reference; model-invocable, hidden from the `/` menu) and `plan`, `approve`, `deliver`, `review`, `learn`, `setup` (lifecycle). `approve`, `deliver`, `review`, `learn` and `setup` set `disable-model-invocation: true` so they run only when the human invokes them and cost no context until then.

## How global standards reach a session

There is one authoritative copy of each global rule, in the plugin's standards skills.

- **Main session:** a `SessionStart` hook (`startup|resume|clear|compact`) prints the body of `engineering-standards` into context. Re-injection after compaction keeps it present.
- **Subagents:** each agent's `skills:` frontmatter preloads `engineering-standards` and its domain standards. SessionStart output is not relied upon for subagents.
- **Domain standards** load on demand in the main session through the Skill tool.
- Consuming projects' `AGENTS.md` holds project facts only.

## Enforcement (plugin hooks)

| Event | Script | Behaviour |
| :- | :- | :- |
| `SessionStart` | `inject-standards.sh` | Adds core standards to the main session. |
| `PreToolUse` Bash | `guard-bash.sh` | Parses the command and classifies each executed action. It returns `ask` for a lone reserved operation (or one preceded only by context-setting commands) and `deny` when a reserved operation is bundled with other commands. It denies Git writes by specialist and reviewer subagents and shell writes to the authority store, and gives implementation agents a non-blocking hint to edit files with Edit/Write. See [Guard v2](#guard-v2-structured-action-classification). |
| `PreToolUse` Write/Edit/NotebookEdit | `guard-writes.sh` | Denies `ai-engineering:learning` writes outside `.agents/`, and writes from any caller to the authority store. |

Plugin agents ignore `hooks`, `permissionMode` and `mcpServers` frontmatter, so all enforcement is plugin-level and filtered by `agent_type` where needed. Plugins cannot ship permission rules, so approval is enforced through the hook rather than `permissions.deny`.

### Human approval semantics

- A hook `ask` forces a permission prompt in default and auto mode; the auto-mode classifier cannot approve it silently. Verified in an interactive auto-mode session: the prompt appeared and declining it prevented execution.
- Where no human can answer (`claude -p`, SDK runs), the ask is treated as a denial and Claude receives the reason.
- Behaviour under `bypassPermissions` is not documented for hook `ask` and has not been verified; do not rely on the guard in that mode.

### Hooks are guardrails, not a security sandbox

The guard sees only the command text Claude submits. It does not see inside scripts, aliases, Makefiles beyond target names, variables, encoded strings or programs that call cloud APIs directly. It errs towards asking: a false positive costs one confirmation. Hard boundaries require OS-level sandboxing, least-privilege credentials, protected branches and environment approvals in CI/CD.

### Guard v2: structured action classification

Decision record: [ADR-0003](decisions/ADR-0003-structured-action-guard.md). Work spec: `WORK-001`.

- **Parse, then classify.** `guard-bash.sh` is a thin wrapper around one jq run: `guard/lexer.jq` splits the command into simple commands and pipelines; `guard/classify.jq` classifies each by program, operation and HTTP method using the declarative tables in `guard/tables.jq`; `guard/policy.jq` decides. Adding a program or verb is a table change with a test.
- **Safety floor by construction.** The v0.2 keyword rules (ask-only) run over the whole command text, at every nesting depth, minus a narrow list of *proven data* spans. Classification and policy can raise the result (deny, precise labels) but never lower it below the floor. A program is never assumed inert: if it has an executing construct (for example `awk system()`, `tar --to-command`, `git -c core.pager`, `git rebase -x`, `--upload-pack`), none of its text counts as data.
- **Proven data, the only exemptions.** These are defined in `guard/tables.jq`, and each has a test with its not-data counterpart:
  - `echo`/`printf` arguments, `cat` operands, and heredoc or here-string input to `cat`, `tee`, `echo` or `printf`, when nothing downstream can run the text;
  - search patterns and paths of `grep`, `rg` and `ag`;
  - `git grep` and `git log -S/-G` values, and `git commit|tag|notes` messages;
  - Git path and revision operands of read and staging subcommands;
  - `sed` scripts made only of `s` commands with no `e` or `w` flag;
  - package names after a package manager's non-task subcommand;
  - URL operands of read-only (GET or HEAD) HTTP requests;
  - `gh release download|view|list` operands;
  - shell comments.
  
  Data is classified only where the receiving program executes it: shell `-c`, `eval`, `ssh` and similar text is parsed recursively, and SQL-client arguments and stdin are scanned for destructive statements. Interpreter inline code (`python -c`, `node -e` and similar) is scanned for destructive SQL only.
- **One operation per approval.** A lone reserved operation, or one preceded only by context-setting commands (`cd`, `pushd`, assignments, `export`, toolchain activation such as `nvm use`), asks. A reserved operation bundled with any other command is denied, with a reason telling the agent to resubmit it alone. A pipeline feeding a SQL client or `xargs` is one operation.
- **Deploy classes.** Deploys are labelled `production-deploy`, `ephemeral-deploy` or `unclassified-deploy`. All of them currently ask.
- **Fail-safe.** When the parse is not confident (unbalanced quotes, a dynamic program name, a parser error, an oversized command, or the time budget is exceeded) the guard applies v0.2-style keyword rules and asks if any match. It never denies for being unparseable, and never returns `allow`.
- **Policy without work-item state.** Specialist and reviewer subagents (identified by `agent_type`) may run only an allow-list of Git read forms. Everything else is denied: writes, `-c` keys outside a small safe list, and options that execute commands. The coordinator owns Git, and the main session is unaffected. Writes to `.agents/specs/**/*.state.json` and the authority-token store under the Git common directory are denied from any caller, through Bash or Write/Edit/NotebookEdit; the plugin's own transition script does not go through tool hooks. Store matching is case-insensitive, treats non-ASCII look-alikes as wildcards (APFS case folding), follows `cd`, `git -C` and `env -C`, and treats glob, brace and dynamic write targets that could reach the store as hits. Hard links into the store are refused. Protection follows an operation's *write effect*, not only literal paths: whole-tree restores, recursive copies and syncs, and archive extractions whose destination can contain the store or `.git` (the repository root, `.agents`, `.agents/specs`, `.git`) ask (`protected-tree-overwrite`), from every caller, without inspecting the source. Git commands that can replace tracked state files (branch switches, merge, pull, rebase, cherry-pick, revert, stash, `reset --hard`, whole-tree restores, the previous-branch shorthand `-` included) ask from the coordinator too. The guard does not inspect Git state at hook time: its only hook-time Git is repository discovery and HEAD's name, through hardened plumbing that reads no objects and no index. A lookup a decision depends on that fails, or that Git variables in the hook environment redirect, asks rather than passing. Implementation agents that edit files through the shell get a non-blocking `additionalContext` hint, never a decision.
- **One classification interface.** `classify_command_impact` in `lib.sh` runs the guard in classify-only mode (an explicit argument, never an environment setting). `run-gate.sh` and `external-review.sh` refuse a configured command classified `ask` or `deny`, or one the guard could not classify.
- **Guard log.** Each `ask` or `deny` appends one JSON line to `<git-common-dir>/ai-engineering/guard-log.jsonl`: time, session id, `agent_type`, decision, classes, parse mode and the SHA-256 of the command, never the command text. It is local, uncommitted, rotated at 1 MiB, and a logging failure never changes the decision. It supports measuring false and true positives.
- **Residual risk.** Scripts, aliases, variables, encoded strings and programs that call APIs directly can still evade the guard. Interpreter inline code is scanned only for destructive SQL. Authority-store protection prevents honest mistakes; it is not a defence against a deliberately adversarial process with shell access.

### Trust boundary for project code

**The plugin is not an isolation boundary.** Running a gate, test or build executes the checked-out project code (package scripts, tests, test configuration, dependencies) with the privileges, files, credentials and network access of whoever runs it. A trusted command such as `npm test` runs untrusted code when the checkout is untrusted. Decision record: [ADR-0002](decisions/ADR-0002-gate-execution-trust-boundary.md).

- **Trusted:** the human, the plugin at its pinned release, and the reviewed base of the target branch.
- **Untrusted until reviewed:** agent edits (an agent can be steered by text in issues, dependencies, web pages or tool output), commits on the work branch, contributors' branches and newly installed dependencies.

The plugin keeps two properties apart:

- **Gate verdict integrity, which the plugin protects.** Implementation checks read `.agents/gates.json` as committed at `HEAD`; uncommitted edits to a committed file are ignored and reported. If nothing is committed at `HEAD` (for example right after setup, or outside git), the gate is `NOT CONFIGURED` and a `NOTE` asks for the file to be committed; an uncommitted file is never run. During `/ai-engineering:review` readiness reads the full gate only from the increment's recorded base commit, with no fallback, and runs it in a fresh clone of `HEAD`, so the change cannot define the gate that certifies it. A change that modifies or adds that gate is named in the verdict line, and a gate defined only by the change is `NOT CONFIGURED`. The `externalReview` command is also read from the base ref. Any configured command the approval guard classifies as high-impact is refused.
- **Host execution safety, which the plugin cannot provide.** Every gate runs through the Claude Code Bash tool, so the user's permission rules and sandbox stay in the execution path, and the plugin adds no unprompted execution route. That keeps the user's chosen boundary; it does not make untrusted code safe. Hooks run outside permissions, the auto-mode classifier and the sandbox, so no plugin hook runs a gate.

Strong isolation of untrusted code needs an appropriately isolated execution environment: CI, a container, a VM or a devcontainer with scoped or no host credentials and appropriate network controls. Hook output (test output, reviewer findings) is untrusted text and may contain instructions; agents treat it as data.

## Reviewer isolation

QA and the security reviewer must run tests, git inspection and security tooling, so they keep Bash. Claude Code offers no supported way to let a Bash-enabled plugin agent run commands while preventing those commands from modifying repository files:

| Mechanism | Why it does not provide the boundary |
| :- | :- |
| Tool lists (current) | Removes Edit/Write/NotebookEdit; Bash can still write. |
| `permissionMode: plan` | Ignored for plugin agents. |
| Bash sandbox | Configured per session, not per agent; allows writes to the working directory by default; implementers need writes in the same session. |
| `isolation: worktree` | Blocks Edit/Write and Bash commands whose working directory or git target is the main checkout, but the documentation does not claim to block a Bash write to an absolute path. The worktree also holds committed state only, without gitignored dependencies, which can stop tests running. |
| PreToolUse allowlist | Test and tooling commands can write (caches, snapshots), so an allowlist is unreliable. |

Current guarantee: reviewers have no file-editing tools and are instructed not to modify files. Nothing more is claimed. Proposed next step (not implemented): a tamper-evidence hook that records a `git status`/diff fingerprint at `SubagentStart` and compares it at `SubagentStop` for the two reviewer agents, reporting any change deterministically. For a hard guarantee, run reviews in CI or in a separately sandboxed session.

## Quality gates

`.agents/gates.json` in each project is the only place gate commands are defined:

```json
{ "fast": "...", "full": "...", "externalReview": null }
```

`scripts/run-gate.sh <name> [directory] [config-ref]` runs a gate in the repository root and prints `GATE <name>: PASSED | FAILED | NOT CONFIGURED | REFUSED`. Unconfigured gates are never reported as passed. Without a config ref only the file committed at `HEAD` is read (implementation checks); if none is committed the gate is `NOT CONFIGURED`, and a `NOTE` asks for any uncommitted file to be committed. Readiness (below) passes the increment's recorded base commit, and only that commit is read (certification).

### Readiness (WORK-003 C2)

`scripts/readiness.sh <WORK-ID> --inc <increment>` is the one readiness procedure. The `review` skill runs it, and `/ai-engineering:deliver` reaches it through `review`. It prints a `READINESS` block ending in `READY: YES | NO`. In v0.3.0 `READY: YES` is not reachable, because base provenance cannot yet be verified (below). The script's header documents every rule; in summary:

- **Effective tier** is the maximum of the state tier, the classifier floor and the action floor. Nothing lowers it. It is computed during readiness only; recomputing after each task commit is deferred to v0.3.x.
- **Base** is the increment's recorded base commit. `workstate.sh` records it only when the increment moves from planned to active. It must be the full commit `origin/<default>` names at that moment (`origin/HEAD` names the default branch), and it never changes: late recording, a different base and re-anchoring are refused. The start command names that exact commit (`git switch -c <branch> <commit>`), and readiness needs that exact command as the guard-log anchor. Otherwise the result is `NOT CERTIFIABLE`:
  - the local `origin/<default>` must still equal the recorded base, so a ref moved to HEAD or to a newer commit is rejected. A newer ref is never accepted automatically, and re-anchoring an increment needs a separate owner workflow (not available in v0.3.0);
  - the base must be an ancestor of HEAD;
  - the increment branch's reflog must show the branch created from it, so a renamed and recreated branch does not count.

  **Base provenance (trust boundary).** The anchor is an `ask` event: it records that the exact start command was asked. It does not show that the owner approved it, that it ran, or that the base is the remote's commit. An agent can plant `origin/<default>` and create the branch with commands the guard does not ask about, even after the owner rejects the start prompt. The ref and the reflog are local records, and remote authenticity is not verified (no `ls-remote`).
  - Owner-approved base provenance is therefore unverified for every increment. The block says `BASE PROVENANCE: UNVERIFIED`, and READY is NO for that reason alone.
  - No workflow reaches `READY: YES` until a separately approved guard change records approval, execution and the remote's commit (proposed in WORK-003). Every other check still runs and is reported, so a run that passes everything else ends `READY: NO - base provenance is unverified (…)`, exit 1.
- **Order:** trust, the classifier and the action floor first, then the external review, then the full gate last, then revalidation. When readiness is already `NOT CERTIFIABLE`, neither the external review nor the gate runs (`NOT RUN (not certifiable)`). After the gate readiness checks again, and treats any change as `NOT CERTIFIABLE`:
  - the spec and state;
  - HEAD, the checked-out branch and `origin/<default>`;
  - replace refs;
  - the installed plugin against its tag;
  - the evidence statuses.

  No earlier result is reused. This catches persistent or accidental changes, not a determined hostile gate (see Limits).
- **Time limits:** the gate is limited to 30 minutes, the external review to 15 and readiness as a whole to 50, clones included. A caller can lower these limits (`READINESS_*_TIMEOUT_SECONDS`) but never raise them.
  - Each child runs in its own process group, together with its watchdog, so every signal targets a group that still has a live member (a reused process-group id is never signalled). The group is stopped on timeout, when the child ends, and when readiness gets INT, TERM or HUP; on a signal readiness exits 4 with no verdict.
  - After the first signal, further INT, TERM and HUP are ignored until the cleanup ends. A signal that was already ignored when readiness started can't be handled: a background job of a non-interactive shell ignores INT, so stop such a run with TERM. A SIGKILL of readiness itself can't be handled: the watchdog then stops the child at its limit.
  - Readiness reads at most the last MiB of a child's output; `run-gate.sh` and `external-review.sh` bound what they print (400 characters a line). The child's whole output is first written to readiness's temporary directory, which has no size limit.
  - A timeout or a missing verdict is a failure.
  - Temporary files and clones are removed on every exit readiness handles.
  - Progress lines go to standard error. The `review` skill runs readiness in the background and waits for the completed result.
- **Fresh clones:**
  - The external review and the full gate each run in their own fresh local clone of the repository at exactly HEAD. Each clone sits in a temporary root separate from readiness's own files.
  - **Controlled Git for clone and checkout.** No user, system or XDG configuration, no attributes (committed ones included), no template and no hooks, so no filter or end-of-line conversion can change what is checked out.
  - **Byte-for-byte verification.** Every tracked file must equal HEAD's blob and mode, and nothing untracked or ignored may exist.
  - Only the increment branch is cloned, through Git's transport (`--no-local`), so objects are copied and every received object is checked (`transfer.fsckObjects`); no hard links, alternates or commit-graph are shared. The clone is checked out on its own branch, `ai-engineering-readiness-gate`; its remote, every other branch and every replace ref are removed. A clone that fails is reported with Git's last message.
  - The clone's local configuration neutralises user-level diff settings, because local configuration overrides user and system configuration. That covers the attributes file (including the XDG default), the big-file threshold, path prefixes, relative and submodule-hiding diffs, each submodule's own `ignore` setting from `.gitmodules` (which only local configuration overrides), and hooks.
  - Readiness reads Git with `GIT_NO_REPLACE_OBJECTS` and `GIT_NO_LAZY_FETCH` set, with `LC_ALL=C`, and without commit-graph files for its ancestry checks. The gate and the external review run without those two variables; their configured command gets the caller's locale. They don't get the controlled configuration either, because the guard treats `GIT_CONFIG_*` and `GIT_NO_REPLACE_OBJECTS` as variables that change what Git reads, and would refuse their commands. Both still receive explicit commits.
- **Environment:** readiness starts in bash privileged mode (`#!/bin/bash -p`) and restarts itself once without `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, exported shell functions, `LD_PRELOAD`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`, `GCONV_PATH`, the library-path variables (`LD_LIBRARY_PATH`, `DYLD_*_PATH`), the Perl variables (`PERL5LIB`, `PERLLIB`, `PERL5OPT`), grep's option variables (`GREP_OPTIONS`, `GREP_COLOR`, `GREP_COLORS`; BSD grep applies `GREP_OPTIONS` to every call) and `POSIXLY_CORRECT` (which would stop bash parsing it), so nothing it runs inherits them. `AI_ENGINEERING_CLASSIFY_MAX_PATHS` and `_MAX_BYTES` are removed too: readiness always classifies with the built-in caps.
  - This is a list of named variables, not an empty environment. Other variables a tool reads (for example `PERL_UNICODE` for `shasum`, `CLICOLOR_FORCE` for `ls`, `TZ`, `MALLOC_*`) still reach readiness's tools and the children; none is known to change a result readiness relies on. An allow-list environment is a separate, deferred design.
  - Its own tools come only from these directories, in this order: `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/home/linuxbrew/.linuxbrew/bin`. The caller's `PATH` is never used for them, so a `jq` or `git` installed only elsewhere (nix, mise, `~/.local/bin`) makes readiness exit 2 with a message naming the directories.
  - Git 2.40 or later is required (older Git ignores `GIT_ATTR_SOURCE`, which readiness uses to switch committed attributes off); older Git exits 2.
  - Every inherited `GIT_*` variable is removed before the first Git command (`git --version` included), so `GIT_TRACE` and the like never apply. Readiness parses with `LC_ALL=C`. `jq` and readiness's helper scripts run with an empty `HOME`, so `~/.jq` is never loaded.
  - `run-gate.sh` and `external-review.sh` run in the same controlled environment, with a private `HOME` and `TMPDIR`. Only their configured command gets the caller's `PATH`, `HOME`, locale, library paths and Perl settings back (`AI_ENGINEERING_COMMAND_PATH`, `AI_ENGINEERING_COMMAND_HOME` and `AI_ENGINEERING_COMMAND_SAVED_<name>`), so the gate's and the reviewer's own tools still come from the caller's `PATH`.
  - The skill runs the script directly. A caller that runs it through another shell (`bash readiness.sh`) defeats this.
  - The fixed directories stop a caller's `PATH` from substituting tools; they are not protected locations. `/opt/homebrew/bin`, `/usr/local/bin` and `/home/linuxbrew/.linuxbrew/bin` are usually writable by the user, so any process running as that user can replace `git`, `jq` or another tool there, and so change any result. Only `/usr/bin`, `/bin`, `/usr/sbin` and `/sbin` are system-owned.
- **External review:** it receives the recorded base and HEAD.
  - At tier 0, when the base commit's `.agents/gates.json` is a valid object whose `externalReview` is explicitly `null`, no review clone is made and none of the checks below apply: the line says `NOT CONFIGURED`, which tier 0 allows. A missing file or key doesn't skip them, and a malformed or oversized file is `NOT CERTIFIABLE`. At tiers 1 and 2 they always run.

  It does not run, and the result is `NOT CERTIFIABLE`, when its own diff could not show the change as it is:
  - an effective `diff.external` (it can't be neutralised: an empty local value breaks `git diff`), so a user-level structural diff tool blocks readiness when a reviewer is configured or the tier is 1 or 2;
  - a changed path that is missing from the reviewer's own `git diff --name-only`, for example a submodule bump hidden by an ignore setting;
  - a changed text file with a `-diff` or `binary` attribute, or with a diff driver that has `textconv`, `command` or `binary` configured, including attributes from a committed `.gitattributes`;
  - any changed file with a configured filter driver.

  The clone has no remote, so a reviewer command must use `REVIEW_BASE_REF` and `REVIEW_HEAD_REF`, not `origin/...`.
- **Full gate:** readiness runs it itself, with configuration from the base commit. It never runs in, falls back to, or links anything from the development checkout (no `node_modules`, `.env` or other ignored files), so the project's `full` gate must be self-contained, installing its own dependencies. The verdict counts only together with `run-gate.sh`'s exit status. Recorded gate results are never trusted. **Running the project's gate is not a security sandbox:** it runs with the user's privileges and can reach user-level resources and absolute paths unless separately isolated.
- **Changed binary files:** a binary change shows every reviewer only `Binary files differ`, so it is allowed only for an image or font asset under a directory that the base commit's `.agents/gates.json` lists in `binaryAssets`.
  - A file counts as binary by Git's own rule, on either side: a NUL byte in the first 8000 bytes, or more than the clones' 512 MiB big-file threshold.
  - Each `binaryAssets` entry must be a relative directory ending in `/`, with no `..` and no hidden segment, and there can be at most 32.
  - The file at HEAD must be mode `100644`, with an allowed extension (`png`, `jpg`, `jpeg`, `gif`, `webp`, `ico`, `avif`, `woff`, `woff2`, `ttf`, `otf`) and that format's leading bytes.
  - Every changed binary is listed under `CHANGED BINARY FILES` with its status, size and SHA-256. A deleted binary is listed and allowed.
  - Anything else is `NOT CERTIFIABLE`: another changed binary (scripts, executables, archives, WebAssembly), an unsafe entry, or a branch that changes `binaryAssets` itself. The allowlist can change only in a separate owner-reviewed change.
  - More than 200 changed binaries is `NOT CERTIFIABLE` (counted before any is read), as is reaching the overall time limit while they are checked. The leading-byte check identifies the format; it doesn't validate the whole file.
- **Tracked files at HEAD:** a path that starts with a double quote or holds a carriage return or newline is `NOT CERTIFIABLE`, because verification could misread it. So is a symbolic link whose target is absolute, leaves the repository, has `..` after a name (that name could itself be a link), holds a control character or cannot be read exactly, because the gate could write through it outside its clone.
  - Paths and targets are split on `/` without pattern expansion, so a directory named `*` or `[ab]` counts as one literal name.
  - In each fresh clone every link is then followed on the real files, with directories resolved physically and at most 40 links, and must end inside the clone in an existing directory; otherwise that clone fails and the result is `NOT CERTIFIABLE`.
- **Working tree and records:**
  - `git status` (with fsmonitor off) must succeed and show only the active item's state and log.
  - No tracked file may be marked assume-unchanged or skip-worktree.
  - A repository with replace refs, a grafts file (`info/grafts`) or local attributes (`info/attributes`) is `NOT CERTIFIABLE`.
  - The temporary directory (`TMPDIR`, default `/tmp`) is resolved to its real path and must be outside the repository, every worktree of it (main and linked) and the working trees of the superprojects it is a submodule of, compared by device and inode so a differently cased path is caught; otherwise readiness exits 2. Other worktrees of a superproject are not checked.
  - Accepted residual: a `TMPDIR` inside an unrelated repository's working tree (a nested checkout that is not a submodule) is allowed. Readiness creates and removes only its own roots there, runs no Git command from them, and leaves that repository unchanged (tested). A Git command that the gate or the reviewer runs from its `TMPDIR` or `HOME` there would find that repository, as any gate command can reach paths outside its clone.
  - The spec and state are read once, from a copy. A failed read is `NOT CERTIFIABLE`, never an empty record.
- **Trusted classifier: a local consistency check, not cryptographic provenance.** These checks compare local records with each other (registry, marketplace clone, tag, installed files). None is authenticated, so they show that the install is internally consistent, not that it came from the publisher. Authenticated provenance (signed releases) is WORK-004; base provenance is reported separately and stays `UNVERIFIED` until authenticated evidence exists. All of these must hold, otherwise the result is `NOT CERTIFIABLE`:
  - readiness runs from the plugin install that Claude Code's registry (`$CLAUDE_CONFIG_DIR`, default `~/.claude`) records for the repository, and every registry entry is strictly validated;
  - that install's version equals the project's base-commit pin and is at least 0.3.0. The pin must have the form `{source, repo, ref: "v<version>"}`, as a GitHub marketplace source does;
  - the marketplace source in `known_marketplaces.json` equals the pin;
  - the install's recorded commit equals the release tag in the marketplace clone;
  - the whole installed tree is byte- and mode-identical to the tag. The runtime `.in_use/` directory, and everything in it, is ignored.

  Signed releases are WORK-004.
- **Action floor:** tier 2 for any trigger-2 decision, or any guard-log `ask` or `deny` after the increment-start anchor, from any session. Events are ordered by line order, never by timestamp. Only `ask` events for three exact commands are excluded, each matched by the SHA-256 of its exact text: the increment start (naming the recorded base commit), the resume of the increment branch, and the merge of a recorded worktree branch. A denial is never excluded. A log rotated or replaced while readiness reads it is `NOT CERTIFIABLE`.
- **NOT CERTIFIABLE** means trust or evidence is missing, ambiguous, malformed or untrusted. Examples: an untrusted install, no state, uncommitted changes, a moved default-branch ref, a missing or malformed guard log, or no anchor. The effective tier is then 2 and READY is NO. It is reported separately from a valid tier-2 classification.
- **Exit codes:**
  - 0: READY: YES (not reachable while base provenance is unverified).
  - 1: READY: NO, certifiable.
  - 3: NOT CERTIFIABLE, so READY: NO.
  - 2: a usage or environment error. Examples: bad arguments, not a Git repository, no `jq` or `git` in the trusted directories, Git older than 2.40, a temporary directory that is unusable or inside the repository, or an environment that can't be cleared. No block is printed.
  - 4: stopped by INT, TERM or HUP. No block is printed, and the run is never READY.
- **Output:** every line of the block has its control characters (newlines included) and every byte outside ASCII shown as `?`, so no Unicode line separator or bidirectional control gets through either. The gate's output is quoted with a `  | ` prefix and the same replacement. A path, record id, guard-log value or gate output therefore can't start a line of its own.
  - Children's output (the gate, the reviewer, Git during clones) goes to files, never to readiness's own output, and cleanup messages are discarded.
  - Every temporary root is removed and checked before the block is printed. A root that can't be removed (the gate made a file immutable, say) is `NOT CERTIFIABLE` and left on disk.
  - Signals are ignored from the start of the report, and nothing is printed after the final `READY:` line. The verdict is that line together with the exit code; progress lines on standard error come only before the block.
- **Depth:**
  - QA evidence is needed at every tier.
  - A security review and a residual-risk list are needed at tier 2. Security categories (auth, secrets, SQL, migrations) always classify as tier 2.
  - External review must be PASSED at tiers 1 and 2. At tier 0, `NOT CONFIGURED` is allowed, so only a genuinely tier-0 increment can pass external review without a configured reviewer. A configured reviewer's `BLOCKING FINDINGS` or `ERROR` is READY: NO at every tier.
  - Review and residual-risk evidence count only when they pass and name a commit that covers HEAD, with only the active item's state and log changed since; renames are not followed. Review evidence must also name its reviewer.
- **Limits:**
  - Evidence and the guard log are workflow records written by the coordinator and the guard. Neither is complete or tamper-proof.
  - A guard-log write that the guard's deadline kills is lost silently.
  - Standalone `/review` without work-item state is always NOT CERTIFIABLE.
  - Remote authenticity of the default-branch ref is not verified, and the guard-log anchor proves neither the owner's approval nor execution (see the trust boundary above).
  - Revalidation after the gate catches persistent or accidental changes, not a determined hostile gate, which runs with readiness's own privileges. Parsing the whole script before it runs (`main`) is defence in depth.
  - A project gate that assumes installed dependencies fails in the fresh clone, which is READY: NO.
  - Practical limits for consuming projects are listed in [consuming-project.md](consuming-project.md#readiness-and-the-version-pin).

## Work items: state and authority

Decision record: [ADR-0004](decisions/ADR-0004-work-authority-and-lifecycle.md). Work spec: `WORK-002`. The procedures live in the `approve`, `deliver` and `review` skills; this section does not restate them.

- **State.** Each work item has a `WORK-NNN.state.json` next to its spec. `scripts/workstate.sh` is the only supported way to change it; its header lists the commands, exit codes and transitions. Commands take a work ID, never a state file path. Writes are atomic and schema-validated, and a corrupt file is refused, never repaired.
- **A workflow record, not security authority.** Owner-only transitions (`approve`, `deliver`) need an owner-command marker passed by the human-only commands. An agent can pass the same flag and anyone can edit the file, so a record never proves owner intent. No guard or hook reads state, and no deploy, merge, publish or protected push depends on it: they ask exactly as before. Signed owner approvals, replay protection and autonomous deployment are WORK-004; the trusted approval path (G1) stays open.
- **Lifecycle.** `proposed`, `approved`, `authorised`, `delivering` (`blocked` and back), `done`, `archived`; `paused` is reachable from the three active states. Changing the spec after approval changes its hash and returns the item to `proposed`.
- **Triggers.** After authorisation delivery interrupts the owner only for an intent or scope change, an owner-level trade-off, accepting or downgrading risk, a reserved operation, or an ambiguity whose readings build different things. Each is recorded with its trigger class. A request that would only add scope, while the approved work can continue, is recorded as an open scope proposal without blocking. The list's single home is the `deliver` skill.
- **Git ownership.** The coordinator creates the branch, commits, merges, pushes the work branch and opens or updates the pull request. Specialists edit and test only; the guard denies their Git writes. Nothing in delivery merges: the owner does.
- **Delivery policy.** The spec's "Delivery policy" section sets `pushWorkBranch` and `openPullRequest` (ready or draft), copied into state at authorisation. Deployment fields and any production, deploy, release or publish entry are rejected with a pointer to WORK-004.
- **Waits and recovery.** `scripts/wait-github.sh` waits for CI checks or the owner's merge as a bounded background command through authenticated `gh`: it validates responses, backs off, times out, never treats an error payload as data and reports `NOT AUTHENTICATED` as a planned owner action. A stalled or failed specialist is re-dispatched once automatically with a fresh brief and the recovery is recorded; a second failure escalates. A specialist the owner stops is an owner pause, not a stall.

## Concurrency

Implementation runs sequentially in one checkout by default. Parallel worktrees are opt-in: `deliver` uses `isolation: "worktree"` only when the owner asks, files are disjoint and the project sets `worktree.baseRef` to `"head"`. Claude Code's default worktree base is the remote default branch, which would not contain the work branch. Worktrees contain committed state only and isolate files only, not databases, ports, `.env` files or infrastructure state; they are not a security boundary. `deliver` runs the fast gate in the agent's worktree.

The guard asks on branch switches and merges, and WORK-002 changes no guard. Delivery therefore causes one confirmation when an increment starts from the updated default branch, plus one per worktree merge when parallel is opted in. That confirmation never replaces, suppresses or pre-authorises any other guard prompt.

## Distribution and updates

- `plugin.json` pins `version`. Claude Code keeps the cached copy, including its hooks, until that string changes, however many commits are pushed.
- Projects register the marketplace at a release tag (`ref: "vX.Y.Z"`) with `autoUpdate: false` (`/setup` writes both). New installs therefore resolve to the tagged release, and nothing updates in the background.
- Limits: marketplace sources accept a branch or tag `ref` but not a commit SHA, and tags can be moved. A user who already registered the marketplace under the same name keeps their existing registration, because project settings only register unknown marketplaces. Updates are explicit: bump the version, tag the release, and update the project's `ref`.

## Deliberately not used in v0.2

- Agent Teams (experimental; no resume, one team per session).
- Executable Claude workflows (no demonstrated need yet; first candidates are parallel implementation and multi-angle review fan-out).
- MCP servers.
- Agent `memory:` as project knowledge (auto memory is per-user and unreviewed; `.agents/` is the source of truth).
- A bootstrap CLI or Node tooling.
