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
