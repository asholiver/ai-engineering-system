# Changelog

## 0.3.0
Unreleased; shared by WORK-001, WORK-002 and WORK-003.

Guard v2: structured action classification (WORK-001, ADR-0003).
- The Bash guard parses commands and classifies executed actions instead of matching text, so keywords in heredocs, string arguments, search patterns and read-only HTTP GETs no longer ask. Shell `-c`/`eval`/`ssh` text and SQL-client input are still classified.
- **Behaviour change:** a compound command that contains a reserved operation alongside other commands is now denied, with a reason telling the agent to resubmit the operation alone. Previously it asked. A lone operation, or one preceded only by context-setting commands, still asks.
- **Behaviour change:** specialist and reviewer subagents can no longer run Git write operations; the coordinator owns Git.
- **Behaviour change:** writes to work-item state files (`.agents/specs/**/*.state.json`) and the authority-token store are denied through Bash and Write/Edit/NotebookEdit. No such files exist in v0.2 projects.
- Deploys are labelled `production-deploy`, `ephemeral-deploy` or `unclassified-deploy` (all still ask); destructive Neon and Vercel CLI operations now ask; HTTP clients are classified by method.
- Unparseable or oversized commands fall back to keyword rules and ask; the guard never returns `allow`. The keyword rules are also a floor over all parsed text except proven data, so nothing v0.2 asked about gets less than `ask`.
- **Behaviour change:** whole-tree restores, recursive copies and syncs, and archive extractions that can overwrite `.git`, `.agents` or the authority store (for example `git checkout <ref> -- .`, `cp -R src/. .`, `tar -xf a.tar` in the repository root) now ask, from every caller. Specialist subagents may run only Git read forms. Git commands that can replace tracked state files (branch switches, merge, rebase, cherry-pick, revert, stash, `reset --hard`) ask in the main session too; the guard does not inspect Git state at hook time.
- `lib.sh` `classify_command_impact` is the single classification interface; gate and external-review commands classified `ask` or `deny` are refused (v0.2 refused only `ask`).
- Local guard log of decisions (classes, parse mode, command hash, never command text) for measuring false positives.
- Implementation-agent instructions: Git is the coordinator's job; edit files with Edit/Write, not the shell. Shell edits get a non-blocking hint.

Change classifier and release consistency (WORK-003 C1).
- `classify-change.sh`: deterministic classification of a change by the paths it touches, so review scope does not depend on model judgement.
- `scripts/check.sh` now fails when `README.md` or `docs/**` pins a version (`ai-engineering-system@vX.Y.Z`, `"ref": "vX.Y.Z"`) that has no `versions/CHANGELOG.md` entry (`scripts/check-doc-versions.sh`). `CONTRIBUTING.md` "Releasing" gains release-notes and upgrade-verification steps.

Work-item lifecycle and delivery (WORK-002, ADR-0004).
- New human-only `/ai-engineering:approve` command and `scripts/workstate.sh`: a work-item state file with a lifecycle (`proposed` to `archived`), spec-hash checks and a delivery policy. Interim owner commands record owner-only transitions; they are workflow records, not security authority, and no guard reads them. Signed approvals and autonomous deployment are WORK-004 (G1 stays open).
- `/ai-engineering:deliver` rewritten: authorises or resumes through `workstate.sh`, runs tasks sequentially by default (parallel worktrees opt-in), owns Git (branch, commits, work-branch push, pull request; never merges), fixes findings inside intent, interrupts only for five triggers (a request that only adds scope is recorded as an open proposal and delivery continues), re-dispatches a failed specialist once automatically (a specialist you stop is a pause), runs review per increment and waits for your merge in the background.
- **Behaviour change:** delivery asks one guard confirmation when each increment starts from the updated default branch (and one per worktree merge when parallel is on). It pre-authorises nothing; every deploy and reserved operation still asks.
- `scripts/wait-github.sh`: bounded, authenticated `gh` wait for checks or merge; `NOT AUTHENTICATED` becomes a planned owner action. Delivery now needs `gh auth login`.
- `/setup` writes `worktree.baseRef: "head"` by default (opt-out documented; it also affects your own `claude --worktree` sessions) and gains v0.2 work-item import. The session banner shows the plugin version and root; check it after upgrading.
- Spec template drops "Implementation state" and "Review state" and gains Increments, Delivery policy and Owner actions; specialist handoffs exclude the log and legacy sections.

Readiness (WORK-003 C2, ADR-0005).
- New `scripts/readiness.sh`: one deterministic readiness procedure that `/ai-engineering:review` runs (and `/ai-engineering:deliver` through it).
  - Effective tier = max(state tier, classifier floor, action floor), and it never goes lower.
  - It runs the full gate itself in a fresh local clone at HEAD, with configuration from the increment's recorded base, and runs the external review.
- **Behaviour change:** an increment starts with `git switch -c <work-branch> <commit>`, naming the full `origin/<default>` commit, so its start record names the base.
  - The guard log records only that the command was asked, not that it was approved or ran, and the base is not authenticated against the remote.
  - **Behaviour change:** readiness therefore reports `BASE PROVENANCE: UNVERIFIED` and never `READY: YES` in v0.3.0. A run that passes everything else ends `READY: NO` for that reason alone (exit 1). A separate guard change, not yet approved, would close this.
  - `workstate.sh increment-set --status active` (planned to active) requires that full commit as `--base-sha`, checks it against `origin/<default>` at that moment, and never records a base later or changes it.
  - A default-branch ref that moves afterwards is `NOT CERTIFIABLE`; a newer ref is never accepted automatically.
- **Behaviour change:** the external review and the gate each run in their own fresh clone of HEAD, review first. Every inherited `GIT_*` variable is removed.
  - Only the increment branch is cloned, through Git's transport with every object checked (`--no-local`, `transfer.fsckObjects`). Clones are checked out with controlled Git (no user, system, XDG or template configuration, no attributes) and verified byte for byte. A failed clone is reported with Git's last message.
  - User-level diff settings and `.gitmodules` ignore settings are neutralised in the clone.
  - An effective `diff.external`, a diff or filter driver on a changed file, or a changed path missing from the reviewer's own diff is `NOT CERTIFIABLE`. At tier 0 with `externalReview` explicitly `null` at the base commit, no review clone is made and these checks don't apply.
- **Behaviour change:** a changed binary file is `NOT CERTIFIABLE` unless it is a non-executable image or font asset under a directory listed in `binaryAssets` in the base commit's `.agents/gates.json`. A branch can't change that list. Each changed binary is listed with its size and SHA-256; more than 200 is `NOT CERTIFIABLE`.
- **Behaviour change:** readiness refuses tracked paths starting with `"` or containing a carriage return or newline, symbolic links that leave the repository or have `..` after a name, a grafts file and `info/attributes`. Link paths are split without pattern expansion, and every link must also resolve inside each fresh clone. Evidence and review diffs never hide a submodule bump.
- **Behaviour change:** readiness runs in bash privileged mode, drops `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, exported functions, preload, gconv, grep-option, `POSIXLY_CORRECT`, library-path and Perl variables for everything it runs (a named list, not an empty environment), and takes its own tools only from fixed directories, never from `PATH` (exit 2 otherwise, as for Git older than 2.40). The Homebrew and `/usr/local` directories among them are usually user-writable, so this stops `PATH` substitution, not same-user tampering. The gate's and the reviewer's configured commands still get the caller's `PATH`, `HOME`, locale, library paths and Perl settings. `TMPDIR` must be outside the repository, its worktrees and any superproject (compared by inode); one inside an unrelated repository is an accepted, documented limitation.
  - Every line of the `READINESS` block has control characters and non-ASCII bytes shown as `?`, and quoted gate output is prefixed `  | `, so nothing reported can forge a block line. Cleanup completes before the block (a leftover is `NOT CERTIFIABLE`) and nothing is printed after it. The verdict is the final `READY:` line with the exit code.
  - The change classifier reports caps and malformed Git output through checked exit statuses, never through marker lines, so inherited grep options cannot hide them.
  - After the gate, readiness revalidates the state, refs, HEAD, replace refs, the installed plugin and the evidence. The whole script is parsed before it runs.
- **Behaviour change:** time limits (gate 30 minutes, external review 15, readiness 50). A timeout fails. INT, TERM or HUP stops the run (exit 4), the child's whole process group and its watchdog, and cleans up. Readiness reads at most the last MiB of a child's output. The `review` skill runs readiness in the background and waits for the result.
- When readiness is already `NOT CERTIFIABLE`, the gate and external review are not run.
- **Behaviour change:** the full gate never runs in the development checkout, so a consuming project's `full` gate must install its own dependencies. Running a project gate is not a sandbox.
- **Behaviour change:** `/ai-engineering:review` no longer takes a base ref, and reports the `READINESS` block.
  - The block can say `NOT CERTIFIABLE`: trust or evidence is missing, ambiguous, malformed or untrusted. The effective tier is then 2 and READY is NO.
  - It is certifiable only from the installed plugin that matches the project's pinned version and its release tag. This is a local consistency check, not cryptographic provenance.
- **Behaviour change:** review depth now depends on the tier.
  - External review is required at tiers 1 and 2, so `NOT CONFIGURED` means READY: NO there. At tier 0 `NOT CONFIGURED` is allowed, but a configured reviewer's `BLOCKING FINDINGS` or `ERROR` is READY: NO at every tier.
  - Security review and a residual-risk list are needed at tier 2.
  - Review evidence must name its reviewer and the commit it covers (`workstate.sh evidence --reviewer qa|security --result pass --sha <commit>`). Tier 2 also needs `--kind residual-risks --result pass --sha <commit>`.
- Readiness fails closed on unreadable or changing work-item records, on an unreadable `git status`, and on files marked assume-unchanged or skip-worktree.
- Action floor from the local guard log: any guard prompt or denial after the increment-start anchor raises the tier to 2. Only the exact start, resume and recorded worktree-merge commands are excluded. New command: `workstate.sh increment-worktree`.
- The change classifier makes files named by hook commands in the base `.claude/settings.json` tier 2.
- `workstate.sh` schema validation now fails closed if the validator itself cannot run, and a state rule that cannot be evaluated stops the command instead of reading as false. Worktree branch names that look like refs (`HEAD`, `origin/…`, `refs/…`) are refused.

Security reviewer execution limits.
- `security-reviewer` follows default execution limits: one simple command per Bash call, bounded inputs (no stress or oversized runs), probes only in an isolated scratch directory, no deletes, no running base or known-vulnerable versions without explicit authorisation, and no retrying a declined command in another form. `/ai-engineering:review` briefs the reviewer with them; exceptions need the owner's authorisation. These are procedural instructions, not a sandbox; the guard and hooks are unchanged.

## 0.2.0
Claude Code native architecture (ADR-0001).
- Repository is now a Claude Code marketplace publishing the `ai-engineering` plugin.
- Specialist roles are native subagents: frontend, backend, platform (implementation), security-reviewer, qa, learning, with model routing in agent frontmatter.
- Planning and orchestration run in the main session through the `plan` and `deliver` skills; `review`, `learn` and `setup` skills added.
- Rules merged into four standards skills with one authoritative copy of each rule; core standards injected at session start and preloaded into agents.
- `workflows/` renamed to playbooks and packaged as the `playbooks` skill.
- Hooks: intent-based human-approval guard for high-impact commands, learning-agent write guard, and an opt-in (`AI_ENGINEERING_HOOK_GATES=1`) bounded fast gate for implementation agents.
- Provider-neutral external review contract (`externalReview` in `.agents/gates.json`); not configured means not ready for final acceptance.
- Removed `models/routing.yaml` and `tooling/` (superseded); README completed (previously truncated).
- Implementation checks read gate commands from `.agents/gates.json` committed at `HEAD`, falling back to the uncommitted file, with a warning, only while none is committed; the external reviewer is read only from the base ref; high-impact configured commands are refused.
- Gate execution trust boundary (ADR-0002), from an independent security review: gates run through the Bash tool by default so the user's permissions and sandbox apply, and the hook no longer executes project code unless opted in; `/ai-engineering:review` reads the full gate from the base ref and reports changes to it. The plugin is documented as not being an isolation boundary.
- `/setup` pins the marketplace to the plugin's release tag with auto-update off; parallel worktree delivery requires `worktree.baseRef: "head"`.
- Added table-driven hook tests and `scripts/check.sh` (including version consistency).

## 0.1.0
Initial reusable AI engineering operating system covering planning, concurrent work sessions, orchestration, specialist agents, independent review, security/scalability/accessibility/performance/SEO/code-quality rules, infrastructure workflows, testing/regression, project knowledge, model routing, token efficiency, deterministic gates, and human decision boundaries.
