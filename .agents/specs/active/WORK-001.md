# Work Specification
## Status
Approved (by Ashley Oliver, 2026-10-06), in principle, with owner decisions D1–D6 incorporated as recorded in `WORK-001-planning.md`. Delivery is not authorised; it may start only after the gate-bootstrap PR (D5) is merged and the owner explicitly authorises it.
## Work ID
WORK-001: Guard v2, structured action classification (v0.3 PR A)
## Objective
Replace text matching in the Bash guard with classification of parsed actions. Success means no false positives in the known Landra categories while every reserved or destructive operation that v0.2 correctly caught is still caught, with each human approval scoped to one operation.

Decision record: [ADR-0003](../../../docs/decisions/ADR-0003-structured-action-guard.md). Programme context: [WORK-001-planning.md](WORK-001-planning.md).
## Scope
Included:
- A parser in `guard-bash.sh` (or a sourced helper) that splits a Bash command into simple commands and pipelines. It must handle:
  - quoting;
  - escapes;
  - comments;
  - operators (`;` `&&` `||` `|` `&`, newlines);
  - heredocs and here-strings;
  - command and process substitution;
  - subshells and grouping;
  - environment-assignment prefixes;
  - wrappers (`sudo`, `env`, `time`, `nice`, `npx`/`pnpm exec`/`bunx`/`uvx`, `xargs`).
- Classification of each simple command by program, operation (subcommand or verb) and, for `curl`, `wget`, `http`, `gh api` and similar, the HTTP method.
- Data handling by receiving program:

  | Receiving program | How its data is treated |
  | :- | :- |
  | Shells: `bash -c`, `sh -c`, `zsh -c`, `eval`, `ssh host <cmd>` | Text is parsed recursively and classified |
  | SQL clients: `psql`, `mysql`, `sqlite3`, `mongosh`, `sqlcmd`, `clickhouse-client`, `turso db shell` | Arguments (`-c`, `-e`) and stdin (pipes, heredocs, here-strings, `-f` files only when the path is in the same command) are scanned for destructive statements |
  | Language interpreters' inline code or stdin: `python -c`, `python -` heredoc, `node -e`, `ruby -e`, `perl -e` | Scanned only for destructive SQL statements, not for tool or deploy words (documented residual category) |
  | Any other program: search and read tools, `echo`, `printf`, `cat`, file-writing redirections | Not scanned |

- Compound policy:
  - **deny** when a command contains a reserved or high-impact operation and at least one other effectful command. The reason tells the agent to resubmit the operation on its own.
  - **ask** for a lone reserved operation, or one preceded only by context-setting commands: `cd`, `pushd`, `export`/`set`/assignment, `source` or `.` of a toolchain activation, `nvm use`, `corepack enable`.
  - A pipeline feeding a SQL client is one operation (`echo "TRUNCATE t" | psql` asks).
- Fail-safe: when parsing isn't confident (unbalanced quotes, a dynamic program name such as `$CMD apply`, or a parser error or timeout), fall back to the v0.2 keyword rules and **ask** if any match. Never deny for being unparseable, and never return `allow`.
- Classes and labels that keep v0.2 coverage:
  - infrastructure apply/destroy;
  - Kubernetes and Helm delete;
  - destructive cloud operations;
  - destructive SQL;
  - force push, remote delete, default-branch and tag pushes;
  - PR/MR merge (CLI and API);
  - release creation;
  - package and image publish;
  - deploy and release tasks or scripts.
- Destructive operations for the platform CLIs in the dogfood stack also ask. For example:
  - `neonctl`/`neon` `branches delete`, `projects delete`, `databases delete`, `roles delete`;
  - `vercel remove`/`rm`, `vercel env rm`, `vercel project rm`, `vercel domains rm`.

  This adds to v0.2 coverage. Keep the tables open to further additions with tests.
- Deploy classes, so WORK-002 can apply delivery policy. **In this spec all of them still ask.**
  - `production-deploy`: for example `vercel --prod`, `vercel deploy --prod`, `vercel promote`, `netlify deploy --prod`.
  - `ephemeral-deploy`: `vercel deploy` or `vercel` without `--prod`/`promote`, `netlify deploy` without `--prod`.
  - `unclassified-deploy`: any other deploy, release or publish task or script, including package-script names.
- HTTP semantics:
  - GET and HEAD (the default for `curl` and `wget` without a body or method flag) are read-only.
  - POST, PUT, PATCH and DELETE to a recognised release, merge or deploy endpoint (for example GitHub `releases`, `pulls/N/merge`, `git/refs` deletes) keep the matching class.
  - Other write methods are not reserved by this guard.
  - `gh release download`/`view`/`list` are read-only; `gh release create`/`delete`/`edit` are reserved.
- Guard policy that needs no work-item state:
  - **Git writes by subagents.** Deny Git write operations when `agent_type` is `ai-engineering:frontend`, `ai-engineering:backend`, `ai-engineering:platform`, `ai-engineering:qa`, `ai-engineering:security-reviewer` or `ai-engineering:learning`. Write operations are `add`, `commit`, `push`, `merge`, `rebase`, `reset`, `restore`, `checkout`/`switch` that change branch or discard files, `branch -d/-D/-m`, `tag`, `stash`, `cherry-pick`, `revert`, `am`, `apply`, `worktree add/remove`, `update-ref`, `gc`/`prune`. Read operations (`status`, `diff`, `log`, `show`, `blame`, `grep`, `ls-files`, `rev-parse`, `merge-base`) stay allowed. The main session (no `agent_type`) is unaffected.
  - **Authority store.** Deny writes, from any caller and through Bash or Write/Edit/NotebookEdit, to:
    - `.agents/specs/**/*.state.json`;
    - the authority-token store (a path under the Git common directory, for example `.git/ai-engineering/tokens/`).

    Writes made by the plugin's own transition script are not routed through tool hooks and are unaffected. Bash detection covers redirections, `tee`, `cp`/`mv`/`ln`/`install`/`rsync`, `sed -i`/`perl -i`, `truncate`, `rm`, and interpreters given those paths as arguments.
  - **Shell-edit hint.** When an implementation agent edits a tracked file through the shell (redirection to an existing tracked file, `sed -i`, `perl -i`, an interpreter heredoc that writes a file), add a non-blocking hint through PreToolUse `additionalContext` with no permission decision: "Use Edit/Write for file changes." If the platform turns out not to support context without a decision, drop the hint and rely on agent instructions. Never ask or deny for this.
- `lib.sh`: one classification interface used by `run-gate.sh` and `external-review.sh`. Both `ask` and `deny` count as high-impact (fixes the v0.2 assumption that only `ask` does).
- A local decision log. One JSON line per `ask` or `deny` in `<git-common-dir>/ai-engineering/guard-log.jsonl`, recording:
  - time;
  - session id;
  - `agent_type`;
  - decision;
  - class labels;
  - parse mode (`parsed` or `fallback`);
  - the SHA-256 of the command text.

  Never the command text itself. Bounded size (rotation or cap); a logging failure never changes the decision.
- Implementation-agent instructions (`frontend.md`, `backend.md`, `platform.md`): Git is the coordinator's job; edit files with Edit/Write, not the shell.

Excluded (non-goals):
- Allowing any deploy autonomously. That is WORK-002, built on the classes defined here.
- Any use of work-item state, risk tiers, gates or review.
- Sandboxing, or claiming the guard is a security boundary.
- Blocking writes before authorisation (owner decision: not initially).
- New agents, MCP, external parser dependencies, or languages other than bash + jq for hook scripts.
## Requirements
- Every hook script stays bash + jq (repository rule). If a requirement can't be met within that constraint, escalate rather than add a dependency.
- The guard never returns `allow`. Possible outputs: nothing, `ask`, `deny`, or context only.
- Deny reasons are written for the agent: name the operation, and say to resubmit it alone or that the coordinator owns Git.
- Ask reasons are written for the human: name the single operation and its class, and keep "Hooks are guardrails, not a sandbox."
- Performance: p95 under 150 ms for commands up to 8 KB, and under 1 s up to 256 KB (large heredocs). Past the parser's size or time budget, use the fallback.
## Business rules
Invariants:
- Destructive and reserved operations are never silently allowed.
- A reserved operation is approved on its own, never bundled with unrelated work.
- An unparseable command is never treated as safe if it contains a reserved keyword.
## Architecture
- Affected areas: `plugins/ai-engineering/scripts/guard-bash.sh` (rewrite, or split into a parser helper plus policy), `guard-writes.sh` (authority-store denial), `lib.sh` (classification interface), `hooks/hooks.json` (only if matchers change), `agents/{frontend,backend,platform}.md`, `tests/run.sh`.
- Parser structure, file layout and the internal representation are left to the implementer.
- Keep classification tables declarative and data-driven, so adding a program or verb is a table change with a test.
## Data
Guard log line (conceptual): `{time, sessionId, agentType, decision, classes[], parseMode, commandSha256}`. Stored locally and uncommitted; per clone, shared by worktrees through the Git common directory.
## API
Hook contract unchanged: PreToolUse JSON in, `hookSpecificOutput` out. `lib.sh` exposes one function answering "is this command high-impact, and which classes", used by the gate scripts.
## UI
Permission prompts show one operation with a precise class label.
## Security
Threats and the controls this spec gives:
- **Reserved keyword hidden in data that the program executes.** Covered by recursive parsing of shell `-c`/`eval`, scanning SQL-client input, and the destructive-SQL scan of interpreter inline code.
- **Splitting evasion** (`a; b`, newline, `&`, substitution `$(...)`, backticks). The parser must treat each as a separate command.
- **Obfuscation** (`te''rraform`, `\terraform`, `"git" push --force`, `command git`, `builtin`, absolute paths `/usr/bin/git`, `git -C dir push -f`, `git -c k=v push`). Normalise before classifying.
- **Unparseable input.** Fallback asks.
- **Authority forgery by tool writes.** Denied for state and token paths.
- **Specialists changing history or pushing.** Denied by `agent_type`.
- **Residual risk**, stated in docs: scripts, aliases, variables, encoded strings and programs calling APIs directly can still evade the guard.
## Scalability and reliability
- Bounded parsing time and log size.
- A failure in the hook (missing jq, internal error) asks, as in v0.2. It never silently allows a command that contains a reserved keyword.
## Observability
- The guard log supports the dogfood metric "guard prompts: false positives / true positives".
- The owner classifies each logged decision afterwards, against the session transcript.
## Testing
Table-driven cases in `tests/run.sh`, fed hook JSON directly (no Claude, no network). Every existing v0.2 case is kept. Any case whose expected result changes is listed in the test with the reason (for example compound commands that now deny).

**Landra false positives: must produce no decision** (reconstructed from the Landra failure record; not verbatim transcripts):
- `python3 - <<'EOF'` whose body replaces text containing "pnpm audit", "vercel deploy --prebuilt", "production deploy", "release" (instance 1).
- `nvm use && "$PLUGIN/scripts/run-gate.sh" fast && git status --short && grep -rn "DROP\|TRUNCATE" --include=*.ts src app scripts tests` (instance 2).
- `python3 -c` or `sed -i` writing source text "in-memory limit is per-instance on serverless platforms; remove the entry" (instance 3). Expected: no decision, and the shell-edit hint when run by an implementation agent.
- `curl -fsSLO https://github.com/org/tool/releases/download/v8.30.1/checksums.txt` (instance 4).
- A `for` loop of `curl -s https://api.github.com/repos/o/r/releases/latest | jq .tag_name` (instance 5).
- `gh release download v1.2.3 -p checksums.txt`, `gh release view`, `gh api repos/o/r/releases/latest`.
- `rg -n 'terraform apply' docs/`, `git log -S 'TRUNCATE'`, `git grep "npm publish"`.
- `cat > notes.md <<'EOF'` with prose mentioning `terraform destroy` and `git push --force`.
- `git commit -m "docs: explain how to deploy and release"`.
- `echo "run npm publish later"`.

**Must still ask** (lone operation):
- the full v0.2 ask list;
- `psql "$URL" -c "DROP DATABASE landra_test"`;
- `echo "TRUNCATE t" | psql`;
- `psql <<'SQL'` with `DROP TABLE x` in the body;
- `bash -c 'npm publish'`;
- `pnpm run deploy`, `pnpm release`;
- `serverless remove --stage prod`, `npx serverless remove`, `sls remove`, `sam delete --stack-name x`;
- `gh release create v1.2.3`;
- `curl -X POST https://api.github.com/repos/o/r/releases`, `gh api -X POST repos/o/r/releases`, `gh api -X PUT repos/o/r/pulls/3/merge`;
- `vercel --prod`, `vercel deploy`, `vercel promote <url>`, `netlify deploy --prod`;
- `cd infra && terraform apply` (context prefix);
- `node -e "await sql\`DROP DATABASE x\`"`;
- `git push --tags`, `./scripts/release.sh`.

**Must deny with "resubmit alone":**
- `psql -c "DROP DATABASE x" && pnpm test` (true-positive shape: destructive SQL in a compound command);
- `pnpm test && git push --force origin feature`;
- `npm run build; npm publish`;
- `git status && gh pr merge 12 --squash`.

**Evasion cases that must ask:**
- `te''rraform apply`, `\terraform apply`, `command terraform apply`, `/usr/local/bin/terraform apply`;
- `git -C repo push -f`, `git -c x=y push origin main`;
- `$(echo terraform) apply` (dynamic, fallback);
- `` `which kubectl` delete pod x ``;
- a newline-separated `cd x` / `terraform apply` sequence (a context prefix, so ask);
- `xargs -I{} kubectl delete pod {}`.

**`agent_type` policy:**
- `ai-engineering:backend` running `git commit -m x` → deny;
- `git push -u origin work` → deny;
- `git status`, `git diff` → none;
- the main session running `git commit` → none;
- `ai-engineering:qa` running `git stash` → deny.

**Authority store:**
- Write/Edit to `.agents/specs/active/WORK-9.state.json` by any caller → deny;
- `echo '{}' > .agents/specs/active/WORK-9.state.json` → deny;
- `cp x .git/ai-engineering/tokens/t` → deny;
- reading those files (`cat`, `jq`) → none.

**Fail-safe:**
- unbalanced-quote command containing `terraform apply` → ask (fallback);
- missing jq → ask;
- an oversized command over the parser budget containing `npm publish` → ask (fallback).

**`lib.sh`:**
- `run-gate.sh` refuses a configured gate that the classifier denies (compound with a reserved operation) as well as one it asks for. Covers both `ask` and `deny`.

**Guard log:**
- an `ask` writes one line with no command text;
- a no-decision command writes nothing;
- an unwritable log directory still returns the correct decision.

Performance: a test asserts the time budget on a 256 KB heredoc, within a tolerance generous enough for CI machines.
## Risks
- **Parser complexity in bash.** Mitigated by a narrow grammar, the fail-safe fallback and table tests. Escalate if bash + jq proves inadequate.
- **New false-positive categories** (for example interpreter inline code containing SQL-like prose). Documented as a residual category; measured through the guard log.
- **Over-denial of compound commands** slowing agents. Mitigated by the context-prefix allowance; measured.
## Acceptance criteria
1. Every Landra false-positive case above produces no decision.
2. Every v0.2 ask case and every must-ask case above still asks, apart from documented compound commands that now deny.
3. Compound commands containing a reserved operation plus other effectful commands deny, with a reason naming the operation and telling the agent to resubmit it alone.
4. Context-prefixed lone reserved operations ask, and don't deny.
5. Deploy commands carry `production-deploy`, `ephemeral-deploy` or `unclassified-deploy` labels and all still ask.
6. Specialist and reviewer subagents are denied Git writes and allowed Git reads. The main session is unaffected.
7. Writes to work-item state files and the token store are denied through Bash and through Write/Edit/NotebookEdit. Reads are unaffected.
8. Unparseable or oversized input falls back to keyword detection and asks. The guard never emits `allow`.
9. `run-gate.sh` and `external-review.sh` refuse configured commands classified as `ask` or `deny`.
10. The guard log records decisions without command text and never affects decisions.
11. `scripts/check.sh` passes, including shellcheck and context budgets.
## Definition of done
- Implementation complete
- Every regression, negative and evasion case passes in `tests/run.sh`
- `scripts/check.sh` passes
- Internal security review (Opus, adversarial) with no unresolved findings, or every finding dispositioned by the owner
- Independent external review passes (see Independent review)
- Human acceptance complete
## Compatibility and migration
- Hook input and output contract unchanged. Consuming projects need no configuration change.
- Behaviour changes for consuming projects:
  - compound commands containing reserved operations now deny instead of ask;
  - specialists can no longer run Git writes;
  - writes to work-state paths are denied (no such files exist in v0.2 projects).

  All three go in the changelog.
- Landra: no change until it is upgraded to v0.3.0.
## Documentation
- `docs/architecture.md`: Enforcement table and "Hooks are guardrails" (parsing, compound-deny, `agent_type` policy, authority store, guard log, residual risks).
- `versions/CHANGELOG.md` (0.3.0 entry, shared with WORK-002 and WORK-003).
- Agent instruction updates as scoped above.
## Independent review
- **Isolation.** Security-sensitive, so it ships as its own PR (PR A) with no unrelated changes.
- **Internal review.** Opus security review on the full diff, with an explicit evasion-hunting brief.
- **External review.** CodeRabbit on the PR at its head SHA, with no unresolved actionable findings. This is the D5 arrangement while v0.2.0 governs; see `WORK-001-planning.md`.
- **Gate scripts.** Under v0.2 the gate commands come from the base ref, but `tests/run.sh` and `scripts/check.sh` are executed from the change itself. Reviewers must check every diff to those two files, and a weakened or removed check is a blocking finding.
- **Owner acceptance.** The owner reviews the changed and added test expectations.
## Dependencies
- None on WORK-002 or WORK-003; can be developed in parallel with WORK-002.
- WORK-002 consumes the deploy classes and the classification interface.
- WORK-003 consumes the classifier through `lib.sh`, and guard-log events as an action-floor input.
## Settled owner decisions
- No pre-authorisation write hook; avoid noisy guards.
- Security-sensitive guard changes are kept isolated.
- The goal is zero known-category false positives without losing true positives.
- Shell-edit discouragement must not create false positives.
- D5: the gate-bootstrap PR is merged before this work starts, and CodeRabbit is the external reviewer for this PR.
## Open decisions
- None. D1–D6 are resolved (see `WORK-001-planning.md`).
## Implementation state
<!-- v0.2 deliver records task status and verdict lines here. Keep entries to one line each; put detailed evidence in WORK-001.log.md so this spec stays small. -->
-
## Review state
<!-- v0.2 review records its status block here. -->
-
