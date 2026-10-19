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
| `SubagentStop` frontend/backend/platform | `gate-fast.sh` | Off by default. Only with `AI_ENGINEERING_HOOK_GATES=1`: runs the `fast` gate in the agent's working tree; failure keeps the agent working for at most 2 fix attempts, then it must report `GATE FAILED`. See [Trust boundary](#trust-boundary-for-project-code). |

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

- **Gate verdict integrity, which the plugin protects.** Implementation checks read `.agents/gates.json` as committed at `HEAD`; uncommitted edits to a committed file are ignored and reported. If nothing is committed at `HEAD` (for example right after setup, or outside git), they fall back to the working-tree file, in the repository or else in `CLAUDE_PROJECT_DIR`, and print a `NOTE`; that verdict can then be defined by uncommitted edits. During `/ai-engineering:review` the full gate is read only from the base ref, with no fallback, so the change cannot define the gate that certifies it. A change that modifies or adds that gate is named in the verdict line, and a gate defined only by the change is `NOT CONFIGURED`. The `externalReview` command is also read from the base ref. Any configured command the approval guard classifies as high-impact is refused.
- **Host execution safety, which the plugin cannot provide.** By default every gate runs through the Claude Code Bash tool, so the user's permission rules and sandbox stay in the execution path, and the plugin adds no unprompted execution route. That keeps the user's chosen boundary; it does not make untrusted code safe. Hooks run outside permissions, the auto-mode classifier and the sandbox, so `gate-fast.sh` executes nothing unless the user sets `AI_ENGINEERING_HOOK_GATES=1`. With it set, each implementation agent's working tree, including uncommitted edits, runs unprompted with the full environment of the Claude Code process. Set it only where the host is itself isolated or the code is trusted, and in your own environment rather than in committed project settings.

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

`scripts/run-gate.sh <name> [directory] [config-ref]` runs a gate in the repository root and prints `GATE <name>: PASSED | FAILED | NOT CONFIGURED | REFUSED`. Unconfigured gates are never reported as passed. Without a config ref the command is read at `HEAD`, falling back to the uncommitted file with a `NOTE` when none is committed (implementation checks). `/ai-engineering:review` passes the base ref, and only that ref is read (certification).

## Work items: state and authority

Decision record: [ADR-0004](decisions/ADR-0004-work-authority-and-lifecycle.md). Work spec: `WORK-002`. The procedures live in the `approve`, `deliver` and `review` skills; this section does not restate them.

- **State.** Each work item has a `WORK-NNN.state.json` next to its spec. `scripts/workstate.sh` is the only supported way to change it; its header lists the commands, exit codes and transitions. Commands take a work ID, never a state file path. Writes are atomic and schema-validated, and a corrupt file is refused, never repaired.
- **A workflow record, not security authority.** Owner-only transitions (`approve`, `deliver`) need an owner-command marker passed by the human-only commands. An agent can pass the same flag and anyone can edit the file, so a record never proves owner intent. No guard or hook reads state, and no deploy, merge, publish or protected push depends on it: they ask exactly as before. Signed owner approvals, replay protection and autonomous deployment are WORK-004; the trusted approval path (G1) stays open.
- **Lifecycle.** `proposed`, `approved`, `authorised`, `delivering` (`blocked` and back), `done`, `archived`; `paused` is reachable from the three active states. Changing the spec after approval changes its hash and returns the item to `proposed`.
- **Triggers.** After authorisation delivery interrupts the owner only for an intent or scope change, an owner-level trade-off, accepting or downgrading risk, a reserved operation, or an ambiguity whose readings build different things. Each is recorded with its trigger class. The list's single home is the `deliver` skill.
- **Git ownership.** The coordinator creates the branch, commits, merges, pushes the work branch and opens or updates the pull request. Specialists edit and test only; the guard denies their Git writes. Nothing in delivery merges: the owner does.
- **Delivery policy.** The spec's "Delivery policy" section sets `pushWorkBranch` and `openPullRequest` (ready or draft), copied into state at authorisation. Deployment fields and any production, deploy, release or publish entry are rejected with a pointer to WORK-004.
- **Waits and recovery.** `scripts/wait-github.sh` waits for CI checks or the owner's merge as a bounded background command through authenticated `gh`: it validates responses, backs off, times out, never treats an error payload as data and reports `NOT AUTHENTICATED` as a planned owner action. A stalled specialist is re-dispatched once with a fresh brief and the recovery is recorded; a second failure escalates.

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
