# Architecture (v0.2)

The system is a Claude Code plugin, `ai-engineering`, published from this repository's marketplace. It prefers native Claude Code mechanisms over custom orchestration. Decision record: [ADR-0001](decisions/ADR-0001-claude-native-architecture.md).

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

Skills: `engineering-standards`, `security-standards`, `frontend-standards`, `platform-standards`, `playbooks` (reference; model-invocable, hidden from the `/` menu) and `plan`, `deliver`, `review`, `learn`, `setup` (lifecycle). `deliver`, `review`, `learn` and `setup` set `disable-model-invocation: true` so they run only when the human invokes them and cost no context until then.

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
| `PreToolUse` Bash | `guard-bash.sh` | Returns `ask` for high-impact operations, classified by intent. |
| `PreToolUse` Write/Edit/NotebookEdit | `guard-writes.sh` | Denies `ai-engineering:learning` writes outside `.agents/`. |
| `SubagentStop` frontend/backend/platform | `gate-fast.sh` | Runs the `fast` gate in the agent's working tree; failure keeps the agent working for at most 2 fix attempts, then it must report `GATE FAILED`. |

Plugin agents ignore `hooks`, `permissionMode` and `mcpServers` frontmatter, so all enforcement is plugin-level and filtered by `agent_type` where needed. Plugins cannot ship permission rules, so approval is enforced through the hook rather than `permissions.deny`.

### Human approval semantics

- A hook `ask` forces a permission prompt in default and auto mode; the auto-mode classifier cannot approve it silently. Verified in an interactive auto-mode session: the prompt appeared and declining it prevented execution.
- Where no human can answer (`claude -p`, SDK runs), the ask is treated as a denial and Claude receives the reason.
- Behaviour under `bypassPermissions` is not documented for hook `ask` and has not been verified; do not rely on the guard in that mode.

### Hooks are guardrails, not a security sandbox

The guard sees only the command text Claude submits. It does not see inside scripts, aliases, Makefiles beyond target names, variables, encoded strings or programs that call cloud APIs directly. It errs towards asking: a false positive costs one confirmation. Hard boundaries require OS-level sandboxing, least-privilege credentials, protected branches and environment approvals in CI/CD.

### Trust boundary for configured commands

Hook scripts, and the gate and review commands they run, execute with the user's full access, **outside** Claude Code's permission rules, the auto-mode classifier and the Bash sandbox. Therefore:

- Gate commands are read from `.agents/gates.json` **as committed at `HEAD`**. Uncommitted edits, including edits by the agent being gated, are ignored and reported. A file that has never been committed is used with a warning.
- The `externalReview` command is read **as committed at the review's base ref**, so a change cannot select or alter its own reviewer.
- Any configured command that the approval guard classifies as high-impact is refused rather than run.
- Enable the plugin only in repositories you trust, and review `gates.json` changes like CI configuration. Hook output (test output, reviewer findings) is untrusted text and may contain instructions; agents treat it as data.

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

`scripts/run-gate.sh <name>` runs a gate in the repository root and prints `GATE <name>: PASSED | FAILED | NOT CONFIGURED | REFUSED`. Unconfigured gates are never reported as passed.

## Concurrency

Implementation runs sequentially in the current checkout by default. `deliver` runs parallel tasks with `isolation: "worktree"` only when files are disjoint and the project sets `worktree.baseRef` to `"head"`. Claude Code's default worktree base is the remote default branch, which would not contain the work branch. Worktrees contain committed state only and isolate files only, not databases, ports, `.env` files or infrastructure state. The fast gate follows the agent into its worktree.

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
